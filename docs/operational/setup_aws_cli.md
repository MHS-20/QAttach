# SetUp AWS CLI

## IAM User vs IAM Role for your terminal

**If you're running commands from your own laptop/desktop:** you need an **IAM user** with an access key. There's no EC2 instance to attach a role to, so a user with programmatic access is the right tool.

**If you're running commands from an EC2 instance or Cloud9:** use an **IAM role** attached to that instance. No credentials to manage.

Since you said "my terminal" I'll assume your laptop.

---

## Step by step: IAM user for your terminal

### 1. Create the IAM user (AWS Console)

Go to **IAM → Users → Create user**. Name it something like `gfs2-cluster-admin`. Do **not** enable AWS Management Console access — you only need programmatic access.

After creating the user, go to **Security credentials → Create access key**. Choose "Command Line Interface (CLI)". Download the CSV — you only get one chance to see the secret key.

### 2. Attach a policy to the user

For the testing phase you need to create and destroy infrastructure freely. Attach the following inline policy (or a managed `AdministratorAccess` policy if you want simplicity during dev — tighten it later):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Full",
      "Effect": "Allow",
      "Action": ["ec2:*"],
      "Resource": "*"
    },
    {
      "Sid": "ASGFull",
      "Effect": "Allow",
      "Action": ["autoscaling:*"],
      "Resource": "*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": ["iam:PassRole", "iam:GetRole"],
      "Resource": "arn:aws:iam::*:role/gfs2-cluster-node-role"
    },
    {
      "Sid": "SSMForSecrets",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:PutParameter",
        "ssm:DeleteParameter"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/gfs2/*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:gfs2/*"
    }
  ]
}
```

`iam:PassRole` is needed specifically to attach the instance role to the launch template — AWS requires explicit permission to "pass" a role to a service.

### 3. Install and configure the AWS CLI

```bash
# Install (macOS)
brew install awscli

# Install (Linux)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Configure
aws configure
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: <your secret>
# Default region name: us-east-1        ← match your deployment region
# Default output format: json
```

This writes to `~/.aws/credentials` and `~/.aws/config`. The CLI picks these up automatically.

### 4. Verify it works

```bash
aws sts get-caller-identity
# Should return your account ID, user ARN, etc.

aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName'
# Should list AZs in your region
```

---

## What credentials the system needs at each layer

It's worth being explicit about the three separate credential sets in play:

| Who | Credential type | Used for |
| --- | --- | --- |
| **Your terminal** | IAM user access key (`~/.aws/credentials`) | Creating infra: instances, volumes, ASG, launch templates |
| **EC2 compute nodes** | IAM instance role (attached to launch template) | `cluster-agent` fencing calls: `StopInstances`, `DetachVolume` |
| **SSH into nodes** | EC2 key pair (`.pem` file) | Logging into instances to test, debug, check logs |

These are completely independent. The instance role is attached automatically when the instance launches — the node never needs to know your personal access key.

---

## SSH key pair setup

```bash
# Create a key pair and save the private key
aws ec2 create-key-pair \
  --key-name gfs2-test \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/gfs2-test.pem

chmod 400 ~/.ssh/gfs2-test.pem

# SSH to an instance using it
ssh -i ~/.ssh/gfs2-test.pem ec2-user@<instance-public-ip>
```

Reference this key pair name in the launch template (see the plan's launch template section) as `KeyName`.

---

## Optional but recommended: named profile

If you work with multiple AWS accounts, use a named profile instead of the default:

```bash
aws configure --profile gfs2-dev
# fills in the same prompts but stores under [gfs2-dev]

# Use it explicitly
aws ec2 describe-instances --profile gfs2-dev

# Or set it as default for the session
export AWS_PROFILE=gfs2-dev
```

That's everything you need. The access key gets your CLI working; the key pair gets you SSH; the instance role handles what `cluster-agent` does at runtime autonomously.

If you already have the key pair from the GUI, you just need the name AWS assigned to it (the name shown in the EC2 console under **Key Pairs**, not the filename of your `.pem`). That name goes directly into the launch template as `KeyName`. Nothing else to do on the key pair side.

---

## What the LLM agent will need to know

Split into two categories: things it needs to **read from your environment** (it can discover these itself with `aws` CLI calls), and things it genuinely **cannot discover** and you must provide upfront.

### Things it can discover itself

```bash
# Account ID
aws sts get-caller-identity --query Account --output text

# Available AZs in the region
aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName'

# Your existing key pair name
aws ec2 describe-key-pairs --query 'KeyPairs[].KeyPairName'

# Default VPC and its subnets
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[].VpcId'
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output table

# What AMIs are available (Amazon Linux 2023, latest)
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId'

# Whether an existing launch template exists
aws ec2 describe-launch-templates --query 'LaunchTemplates[].LaunchTemplateName'
```

Tell the LLM to run these at the start of any provisioning session rather than having you paste the values.

### Things you must provide — it cannot discover these

| What | Why it can't discover it | How to get it |
| --- | --- | --- |
| **Which AZ to use** | There are multiple and only you know which one your workload targets | Pick one, e.g. `us-east-1a`. All compute nodes and the EBS volume must be in the same AZ. |
| **Your `.pem` file path** | The LLM runs on your terminal but doesn't know your filesystem | E.g. `~/.ssh/my-keypair.pem` |
| **etcd node IPs or NLB DNS** | These are created during setup, before the LLM knows them | After etcd nodes are created, feed the IPs back |
| **The EBS volume ID** | Created during setup | Feed back after `create-volume` runs |
| **Your cluster name tag** | Arbitrary string you choose | E.g. `mycluster` — used in tags and GFS2 lock table |
| **The region** | Could be anything | E.g. `us-east-1` — set in `AWS_DEFAULT_REGION` or `~/.aws/config` |

The launch template ID is **not** something you need to provide upfront — the LLM creates it as part of setup and can query it afterward with `describe-launch-templates`. Same for the IAM role ARN, security group ID, subnet ID — these are all outputs of the provisioning steps, not inputs.

---

## The minimal "context file" to give the LLM at session start

Rather than answering questions one by one, give the agent a small context block at the start of every session. Something like:

```
Environment:
  region: us-east-1
  az: us-east-1a
  key_pair_name: my-existing-keypair        ← name in AWS console, not filename
  pem_path: ~/.ssh/my-existing-keypair.pem
  cluster_name: mycluster
  aws_profile: default                      ← or your named profile
```

Everything else — account ID, VPC, subnet, AMI, volume ID, launch template ID, IAM role ARN — the LLM discovers or creates itself and should store in a local state file (e.g. `cluster-state.json`) that it updates as provisioning progresses, so it can resume a session without losing track of created resource IDs.

---

## One practical tip on the launch template ID

The launch template ID (`lt-0abc123...`) is only needed when you want to launch instances manually outside of an ASG, or when updating the template. For ASG-based workflows the ASG references the template by name, which is stable. So in practice you reference it by name (`gfs2-compute-template`) not by ID, and the LLM can look it up anytime with `describe-launch-templates --launch-template-names gfs2-compute-template`.