#!/usr/bin/env groovy
//
// pms-order-bteam 2대 EC2 롤링 + 인스턴스 내부 nginx Blue/Green 배포 오케스트레이터.
//
// 호출 계약: pms-order-bteam PR #5 README "오케스트레이터 인터페이스" 섹션 그대로 사용.
//   - ~/app 자산 동기화 (docker-compose.deploy.yml → docker-compose.yml, nginx/, scripts/)
//   - ECR_REPO / IMAGE_TAG / SPRING_PROFILES_ACTIVE export 후 deploy.sh 호출
//   - 종료 코드 0 → stdout 마지막 줄(OLD_COLOR) 파싱 → ALB healthy 검증 → stop-old-color.sh
//   - 종료 코드 1 → 앱 측이 이미 자가 복구. 본 파이프라인은 abort, 다음 인스턴스 미접촉.
//
// 호스트 도달은 SSH가 아닌 AWS SSM Run Command. 자산은 Jenkins workspace에서
// tar+base64 인코딩되어 SSM commands에 인라인 전송 (앱 EC2의 GitHub 접근 불필요).

pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        ansiColor('xterm')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    triggers {
        githubPush()
    }

    parameters {
        string(name: 'APP_REF',
               defaultValue: 'main',
               description: 'pms-order-bteam git ref (branch/tag/sha)')
        string(name: 'IMAGE_TAG',
               defaultValue: '',
               description: 'ECR 이미지 태그. 비우면 ${shortSha}-b${BUILD_NUMBER} 자동 생성')
        choice(name: 'SPRING_PROFILES_ACTIVE',
               choices: ['prod'],
               description: '앱 Spring profile')
        booleanParam(name: 'SKIP_BUILD',
                     defaultValue: false,
                     description: 'docker build/push 생략 (재배포 / 롤백 용)')
        booleanParam(name: 'DRY_RUN',
                     defaultValue: false,
                     description: '모든 mutation을 echo만 하고 실제 실행은 안 함')
    }

    environment {
        APP_REPO       = 'https://github.com/protect-my-service/pms-order-bteam.git'
        SSM_PREFIX     = '/pms-order/prod/app'
        SSM_LOG_GROUP  = '/ssm/pms-order-deploy'
        AWS_PAGER      = ''
    }

    stages {
        stage('Checkout app') {
            steps {
                script {
                    dir('app') {
                        deleteDir()
                    }
                    withCredentials([usernamePassword(credentialsId: 'github-pat',
                                                     usernameVariable: 'GH_USER',
                                                     passwordVariable: 'GH_TOKEN')]) {
                        dir('app') {
                            checkout([
                                $class: 'GitSCM',
                                branches: [[name: "*/${params.APP_REF}"]],
                                userRemoteConfigs: [[
                                    url: env.APP_REPO,
                                    credentialsId: 'github-pat',
                                ]],
                                extensions: [[$class: 'CloneOption', depth: 1, shallow: true, noTags: false]],
                            ])
                        }
                    }
                    env.APP_SHA = sh(script: 'git -C app rev-parse --short=7 HEAD', returnStdout: true).trim()
                    echo "Checked out pms-order-bteam @ ${params.APP_REF} (${env.APP_SHA})"
                }
            }
        }

        stage('Resolve config') {
            steps {
                script {
                    def names = ['INSTANCE_IDS', 'TG_ARN', 'ECR_REPO', 'AWS_REGION', 'HEALTH_PATH']
                    def joined = names.collect { "${env.SSM_PREFIX}/${it}" }.join(' ')

                    // 첫 SSM 호출은 region 미해결 상태이므로 metadata에서 region 한 번 조회.
                    // (ssm get-parameters는 region 인자 필요. 컨테이너 내부에서 IMDSv2로 조회 가능)
                    def region = sh(
                        script: '''set -e
                          TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
                            -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
                          curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
                            http://169.254.169.254/latest/meta-data/placement/region''',
                        returnStdout: true
                    ).trim()
                    env.AWS_DEFAULT_REGION = region

                    def raw = sh(
                        script: "aws ssm get-parameters --region ${region} --names ${joined} --output json",
                        returnStdout: true
                    ).trim()
                    def parsed = readJSON text: raw
                    if (parsed.InvalidParameters && parsed.InvalidParameters.size() > 0) {
                        error "SSM에서 누락된 키: ${parsed.InvalidParameters.join(', ')}"
                    }

                    def kv = [:]
                    parsed.Parameters.each { p ->
                        def shortName = p.Name.tokenize('/').last()
                        kv[shortName] = p.Value
                    }

                    env.INSTANCE_IDS = kv['INSTANCE_IDS']
                    env.TG_ARN       = kv['TG_ARN']
                    env.ECR_REPO     = kv['ECR_REPO']
                    env.APP_REGION   = kv['AWS_REGION']
                    env.HEALTH_PATH  = kv['HEALTH_PATH']

                    if (env.APP_REGION != region) {
                        echo "WARN: SSM AWS_REGION(${env.APP_REGION}) ≠ controller region(${region}). 앱 region을 사용."
                        env.AWS_DEFAULT_REGION = env.APP_REGION
                    }

                    env.RESOLVED_IMAGE_TAG = params.IMAGE_TAG?.trim() ?: "${env.APP_SHA}-b${env.BUILD_NUMBER}"

                    echo """
                        ── Resolved ──
                          INSTANCE_IDS = ${env.INSTANCE_IDS}
                          TG_ARN       = ${env.TG_ARN}
                          ECR_REPO     = ${env.ECR_REPO}
                          REGION       = ${env.AWS_DEFAULT_REGION}
                          HEALTH_PATH  = ${env.HEALTH_PATH}
                          IMAGE_TAG    = ${env.RESOLVED_IMAGE_TAG}
                          DRY_RUN      = ${params.DRY_RUN}
                          SKIP_BUILD   = ${params.SKIP_BUILD}
                    """.stripIndent()
                }
            }
        }

        stage('Build & push image') {
            when { expression { !params.SKIP_BUILD } }
            steps {
                script {
                    def fullTag = "${env.ECR_REPO}:${env.RESOLVED_IMAGE_TAG}"
                    def registry = env.ECR_REPO.tokenize('/')[0]

                    if (params.DRY_RUN) {
                        echo "[DRY_RUN] would docker build/push ${fullTag}"
                        return
                    }

                    sh """set -e
                      aws ecr get-login-password --region ${env.AWS_DEFAULT_REGION} \
                        | docker login --username AWS --password-stdin ${registry}
                      docker build -t ${fullTag} -f app/Dockerfile app
                      docker push ${fullTag}
                    """
                    echo "Pushed ${fullTag}"
                }
            }
        }

        stage('Rolling deploy') {
            steps {
                script {
                    def ids = env.INSTANCE_IDS.split(',').collect { it.trim() }.findAll { it }
                    if (ids.isEmpty()) error "INSTANCE_IDS가 비어 있음"

                    echo "롤링 대상(순차): ${ids.join(' → ')}"

                    def deployBundle = buildAssetBundle()  // base64(tar.gz)
                    def deployScript = buildDeployScript(deployBundle)

                    ids.eachWithIndex { id, idx ->
                        stage("Deploy ${id} (${idx + 1}/${ids.size()})") {
                            deployOne(id, deployScript, deployBundle)
                        }
                    }
                }
            }
        }
    }

    post {
        success { script { notifySlack('SUCCESS') } }
        failure { script { notifySlack('FAILURE') } }
        aborted { script { notifySlack('ABORTED') } }
        always  { sh 'docker logout || true' }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 헬퍼
// ─────────────────────────────────────────────────────────────────────────────

// 한 인스턴스에 대한 전체 흐름.
// PR #5 오케스트레이터 인터페이스: deregister → drain → deploy.sh → register → ALB healthy
//                                  → stop-old-color.sh.
// 실패 시: 해당 인스턴스는 ALB에서 빠진 채로 두고 throw → 다음 인스턴스 미접촉.
def deployOne(String instanceId, String deployScript, String bundleB64) {
    timeout(time: 15, unit: 'MINUTES') {
        // 1. 사전 health check: 이 노드가 healthy 가 아니면 만지지 않는다.
        def health = sh(
            script: """aws elbv2 describe-target-health \
              --target-group-arn ${env.TG_ARN} \
              --targets Id=${instanceId} \
              --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text""",
            returnStdout: true
        ).trim()
        echo "[${instanceId}] preCheck: state=${health}"
        if (health != 'healthy' && !params.DRY_RUN) {
            error "사전 상태가 healthy가 아님 (${health}). 운영자 점검 필요."
        }

        // 2. ALB에서 deregister
        if (params.DRY_RUN) {
            echo "[DRY_RUN] would deregister ${instanceId}"
        } else {
            sh "aws elbv2 deregister-targets --target-group-arn ${env.TG_ARN} --targets Id=${instanceId}"
            sh "aws elbv2 wait target-deregistered --target-group-arn ${env.TG_ARN} --targets Id=${instanceId}"
        }

        // 3. SSM으로 deploy 실행
        def oldColor
        if (params.DRY_RUN) {
            echo "[DRY_RUN] would SSM run deploy on ${instanceId}"
            oldColor = 'blue'
        } else {
            def out = runOnInstance(instanceId, deployScript, 600)
            oldColor = parseOldColor(out)
            echo "[${instanceId}] deploy 성공. old color = ${oldColor}"
        }

        // 4. ALB에 register + healthy 대기
        def healthy = registerAndWait(instanceId)

        // 5. healthy 실패 → 1회 자동 롤백 시도
        if (!healthy) {
            echo "[${instanceId}] ALB healthy 실패 → nginx를 ${oldColor}로 자동 롤백 시도"
            if (!params.DRY_RUN) {
                runOnInstance(instanceId, buildRollbackScript(oldColor), 120)
                healthy = registerAndWait(instanceId)
            } else {
                healthy = true
            }
            if (!healthy) {
                error "[${instanceId}] 롤백 후에도 ALB healthy 실패. 노드를 ALB 외부에 둔 채로 abort."
            }
        }

        // 6. old color stop. 실패해도 트래픽 영향 없음 → warning만.
        if (params.DRY_RUN) {
            echo "[DRY_RUN] would stop old color ${oldColor} on ${instanceId}"
        } else {
            try {
                runOnInstance(instanceId, "set -e\ncd \$HOME/app && bash scripts/stop-old-color.sh ${oldColor}", 120)
            } catch (Throwable t) {
                echo "[${instanceId}] WARN: stop-old-color.sh 실패 (${t.message}). 새 색상은 정상 서비스 중. 다음 인스턴스로 진행."
            }
        }
    }
}

// register + wait target-in-service. healthy면 true, timeout이면 false.
def registerAndWait(String instanceId) {
    if (params.DRY_RUN) {
        echo "[DRY_RUN] would register ${instanceId} + wait healthy"
        return true
    }
    sh "aws elbv2 register-targets --target-group-arn ${env.TG_ARN} --targets Id=${instanceId}"
    try {
        timeout(time: 5, unit: 'MINUTES') {
            sh "aws elbv2 wait target-in-service --target-group-arn ${env.TG_ARN} --targets Id=${instanceId}"
        }
        return true
    } catch (Throwable t) {
        echo "[${instanceId}] wait target-in-service 실패: ${t.message}"
        return false
    }
}

// 워크스페이스의 docker-compose.deploy.yml + nginx/ + scripts/ 를
// tar.gz + base64로 묶는다. SSM commands(24KB)에 인라인 전송 가능한 크기.
def buildAssetBundle() {
    sh '''set -e
      cd app
      tar -czf ../bundle.tgz docker-compose.deploy.yml nginx scripts
      cd ..
      base64 -w0 bundle.tgz > bundle.b64 2>/dev/null || base64 bundle.tgz | tr -d '\\n' > bundle.b64
      wc -c bundle.b64
    '''
    def b64 = readFile('bundle.b64').trim()
    if (b64.length() > 18000) {
        echo "WARN: 번들 base64 크기 ${b64.length()}B — SSM 24KB 한도 근접. 24KB 초과 시 S3 stage로 전환 필요."
    }
    return b64
}

// EC2에서 실행될 셸 스크립트 본문.
// $HOME/app 에 자산을 풀고, ECR 로그인 후 deploy.sh 실행, OLD_COLOR 마커 출력.
def buildDeployScript(String bundleB64) {
    return """#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /tmp/deploy.\$\$.log) 2>&1

[[ -f \$HOME/app/.env ]] || { echo "FATAL: ~/app/.env 가 없음. 운영자가 사전 작성 필요."; exit 2; }

mkdir -p \$HOME/app
cd \$HOME/app

# 자산 배치 (기존 nginx/scripts/docker-compose.yml 덮어쓰기). state/ 는 보존.
echo "${bundleB64}" | base64 -d > /tmp/bundle.tgz
rm -rf nginx scripts docker-compose.yml
tar -xzf /tmp/bundle.tgz
mv -f docker-compose.deploy.yml docker-compose.yml
rm -f /tmp/bundle.tgz

export ECR_REPO="${env.ECR_REPO}"
export IMAGE_TAG="${env.RESOLVED_IMAGE_TAG}"
export SPRING_PROFILES_ACTIVE="${params.SPRING_PROFILES_ACTIVE}"

# ECR 로그인 (앱 EC2 instance profile에 ECR pull 권한 전제)
aws ecr get-login-password --region "${env.AWS_DEFAULT_REGION}" \\
  | docker login --username AWS --password-stdin "\${ECR_REPO%%/*}"

# deploy.sh stdout 마지막 줄 = old color. 트렁케이션 안전 위해 OLD_COLOR= 마커 추가 출력.
OLD=\$(bash \$HOME/app/scripts/deploy.sh "${env.HEALTH_PATH}" | tail -n1)
echo "OLD_COLOR=\${OLD}"
"""
}

// ALB healthy 실패 시 nginx upstream을 이전 색상으로 즉시 되돌리는 스크립트.
def buildRollbackScript(String oldColor) {
    return """#!/usr/bin/env bash
set -euo pipefail
cd \$HOME/app
cp -f nginx/templates/upstream-${oldColor}.conf nginx/conf.d/upstream.conf
docker compose -f docker-compose.yml exec -T nginx nginx -t
docker compose -f docker-compose.yml exec -T nginx nginx -s reload
echo "ROLLBACK_TO=${oldColor}"
"""
}

def parseOldColor(String stdout) {
    def m = (stdout =~ /(?m)^OLD_COLOR=(blue|green)$/)
    if (!m.find()) {
        echo "----- SSM stdout (truncated to last 4KB) -----"
        echo stdout.length() > 4000 ? stdout[-4000..-1] : stdout
        error "OLD_COLOR= 마커를 찾지 못함. 전체 로그는 CloudWatch ${env.SSM_LOG_GROUP} 참조."
    }
    return m.group(1)
}

// SSM Run Command 송신 + 폴링 + 결과 반환.
// scriptContent는 base64 인코딩되어 commands 인라인으로 전송된다.
// 전체 stdout/stderr는 CloudWatch Logs에도 동시 송출 (SSM_LOG_GROUP).
def runOnInstance(String instanceId, String scriptContent, int timeoutSec) {
    def b64Script = java.util.Base64.encoder.encodeToString(scriptContent.bytes)
    def wrapper = "bash -c 'echo ${b64Script} | base64 -d | bash'"

    def paramsJson = "params-${instanceId}-${env.BUILD_NUMBER}.json"
    writeJSON file: paramsJson, json: [commands: [wrapper]]

    def commandId = sh(
        script: """aws ssm send-command \
          --document-name AWS-RunShellScript \
          --instance-ids ${instanceId} \
          --comment "jenkins-${env.JOB_NAME}-${env.BUILD_NUMBER}" \
          --parameters file://${paramsJson} \
          --cloud-watch-output-config CloudWatchOutputEnabled=true,CloudWatchLogGroupName=${env.SSM_LOG_GROUP} \
          --query 'Command.CommandId' --output text""",
        returnStdout: true
    ).trim()
    sh "rm -f ${paramsJson}"

    echo "[${instanceId}] SSM CommandId=${commandId} (CloudWatch ${env.SSM_LOG_GROUP})"

    def deadline = System.currentTimeMillis() + (timeoutSec * 1000L)
    def status = ''
    def stdout = ''
    def stderr = ''
    while (System.currentTimeMillis() < deadline) {
        sleep time: 5, unit: 'SECONDS'
        def raw = sh(
            script: """aws ssm get-command-invocation \
              --command-id ${commandId} --instance-id ${instanceId} --output json || true""",
            returnStdout: true
        ).trim()
        if (!raw) continue
        def inv
        try { inv = readJSON text: raw } catch (Throwable t) { continue }
        status = inv.Status ?: ''
        stdout = inv.StandardOutputContent ?: ''
        stderr = inv.StandardErrorContent ?: ''
        if (status in ['Success', 'Failed', 'Cancelled', 'TimedOut']) break
    }

    echo "----- [${instanceId}] SSM stdout (≤24KB) -----\n${stdout}"
    if (stderr?.trim()) echo "----- [${instanceId}] SSM stderr (≤8KB) -----\n${stderr}"

    if (status != 'Success') {
        error "[${instanceId}] SSM command ${commandId} 종료 상태=${status}. 전체 로그는 CloudWatch ${env.SSM_LOG_GROUP} 참조."
    }
    return stdout
}

def notifySlack(String status) {
    def msg = "[${status}] ${env.JOB_NAME} #${env.BUILD_NUMBER} — APP_REF=${params.APP_REF}, IMAGE_TAG=${env.RESOLVED_IMAGE_TAG ?: '(unresolved)'}\n${env.BUILD_URL}"
    try {
        slackSend(color: status == 'SUCCESS' ? 'good' : (status == 'ABORTED' ? 'warning' : 'danger'), message: msg)
    } catch (Throwable t) {
        echo "slack notify skipped: ${t.message}"
    }
}
