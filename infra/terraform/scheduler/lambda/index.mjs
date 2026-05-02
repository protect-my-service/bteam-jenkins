import {
  EC2Client,
  DescribeInstancesCommand,
  StopInstancesCommand,
  StartInstancesCommand,
} from "@aws-sdk/client-ec2";
import {
  RDSClient,
  DescribeDBInstancesCommand,
  DescribeDBClustersCommand,
  ListTagsForResourceCommand,
  StopDBInstanceCommand,
  StartDBInstanceCommand,
  StopDBClusterCommand,
  StartDBClusterCommand,
} from "@aws-sdk/client-rds";

const region = process.env.AWS_REGION || "us-east-1";
const tagKey = process.env.TAG_KEY || "AutoStop";
const tagValue = process.env.TAG_VALUE || "true";

const ec2 = new EC2Client({ region });
const rds = new RDSClient({ region });

export const handler = async (event) => {
  const action = event?.action === "start" ? "start" : "stop";
  console.log(`scheduler invoked action=${action} tag=${tagKey}=${tagValue}`);

  const results = await Promise.allSettled([
    handleEc2(action),
    handleRdsInstances(action),
    handleRdsClusters(action),
  ]);

  results.forEach((r, i) => {
    const label = ["ec2", "rds-instance", "rds-cluster"][i];
    if (r.status === "rejected") console.error(`${label} failed:`, r.reason);
    else console.log(`${label} ok:`, JSON.stringify(r.value));
  });

  return { statusCode: 200, action };
};

async function handleEc2(action) {
  const targetState = action === "stop" ? "running" : "stopped";
  const res = await ec2.send(
    new DescribeInstancesCommand({
      Filters: [
        { Name: `tag:${tagKey}`, Values: [tagValue] },
        { Name: "instance-state-name", Values: [targetState] },
      ],
    }),
  );
  const ids = res.Reservations.flatMap((r) =>
    r.Instances.map((i) => i.InstanceId),
  );
  if (ids.length === 0) return { skipped: true, reason: "no targets" };

  if (action === "stop") {
    await ec2.send(new StopInstancesCommand({ InstanceIds: ids }));
  } else {
    await ec2.send(new StartInstancesCommand({ InstanceIds: ids }));
  }
  return { action, ids };
}

async function handleRdsInstances(action) {
  const res = await rds.send(new DescribeDBInstancesCommand({}));
  // Aurora 클러스터 멤버 인스턴스는 cluster 단위로 처리하므로 제외.
  const standalone = res.DBInstances.filter((d) => !d.DBClusterIdentifier);
  const targets = await filterByTag(standalone, (d) => d.DBInstanceArn);

  const targetState = action === "stop" ? "available" : "stopped";
  const eligible = targets.filter((d) => d.DBInstanceStatus === targetState);

  const ops = await Promise.allSettled(
    eligible.map((d) => {
      const id = d.DBInstanceIdentifier;
      return action === "stop"
        ? rds.send(new StopDBInstanceCommand({ DBInstanceIdentifier: id }))
        : rds.send(new StartDBInstanceCommand({ DBInstanceIdentifier: id }));
    }),
  );

  return {
    action,
    ids: eligible.map((d) => d.DBInstanceIdentifier),
    failures: ops.filter((o) => o.status === "rejected").length,
  };
}

async function handleRdsClusters(action) {
  const res = await rds.send(new DescribeDBClustersCommand({}));
  const targets = await filterByTag(res.DBClusters, (c) => c.DBClusterArn);

  const targetState = action === "stop" ? "available" : "stopped";
  const eligible = targets.filter((c) => c.Status === targetState);

  const ops = await Promise.allSettled(
    eligible.map((c) => {
      const id = c.DBClusterIdentifier;
      return action === "stop"
        ? rds.send(new StopDBClusterCommand({ DBClusterIdentifier: id }))
        : rds.send(new StartDBClusterCommand({ DBClusterIdentifier: id }));
    }),
  );

  return {
    action,
    ids: eligible.map((c) => c.DBClusterIdentifier),
    failures: ops.filter((o) => o.status === "rejected").length,
  };
}

async function filterByTag(items, getArn) {
  const out = [];
  for (const item of items) {
    const tags = await rds.send(
      new ListTagsForResourceCommand({ ResourceName: getArn(item) }),
    );
    const matched = (tags.TagList || []).some(
      (t) => t.Key === tagKey && t.Value === tagValue,
    );
    if (matched) out.push(item);
  }
  return out;
}
