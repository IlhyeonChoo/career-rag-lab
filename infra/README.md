# Week 2 AWS deployment

### 1. Open CloudShell in the personal AWS account

Sign in to the AWS console for the **personal lab account**, select **Asia Pacific (Seoul)**, and open **CloudShell** from the console toolbar. Use the standard CloudShell environment. The session uses the console identity. Check the account number against the personal account before deployment. Docker, Git, jq and AWS CLI run inside CloudShell. [CloudShell software](https://docs.aws.amazon.com/cloudshell/latest/userguide/vm-specs.html)

```bash
export AWS_REGION=ap-northeast-2
aws sts get-caller-identity --query Account --output text
git clone https://github.com/IlhyeonChoo/career-rag-lab.git
cd career-rag-lab
docker version --format '{{.Server.Version}}'
```

### 2. Select a subnet

List candidate default subnets in Seoul. These commands only read the account’s network configuration.

```bash
aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters Name=default-for-az,Values=true Name=state,Values=available \
  --query 'Subnets[].[SubnetId,VpcId,AvailabilityZone]' --output table
```

Copy a subnet ID from the table. If the table is empty, open **VPC → Subnets**, select an existing lab subnet and open its **Route table** tab. Choose a subnet with an active IPv4 route from `0.0.0.0/0` to an internet gateway (`igw-…`). Use a VPC with DNS resolution enabled and network ACLs permitting HTTPS and return traffic. If the account has no such subnet, prepare a public subnet with that route before deployment. The deployment script checks the route before it provisions resources.

### 3. Deploy and capture the evidence

```bash
read -rp 'Paste the selected subnet ID: ' SUBNET_ID
export SUBNET_ID
bash infra/deploy.sh
```

The default stack is `rag-week2-lab`. The script builds a Linux AMD64 image with the default Docker builder, provisions the stack, pushes to a private ECR repository, uploads the synthetic fixture to the private bucket, then runs one Fargate task. The task binds to loopback and makes HTTP requests to its own API. A public task IP provides outbound connectivity during the test. The security group has no inbound rule.

The task execution role allows pulling from this ECR repository and writing to the lab log stream. The application role can only get `week2/sample.json` from the new S3 bucket. S3 blocks public access and requires HTTPS. CloudWatch retains logs for seven days. Do not store real documents or unrelated images in these lab resources.

For the report, capture the terminal or open **CloudWatch Logs → Log groups**, then select the group and stream printed by the script. Record the two HTTP 200 lines, the S3 source in the sample response, and `SMOKE TEST PASSED`. The terminal also prints the Fargate task ID, STOPPED state and exit code 0. The stopped state is expected for the one-shot test. If the task fails, check its stopped reason and log stream. Save the evidence before deleting the stack.

### 4. Remove the lab resources

Fargate compute, the public IPv4 address, ECR, S3 and CloudWatch can incur charges. The compute and address are released after the task stops. The image, object and log group remain until cleanup. To remove this lab, use the same CloudShell account and region and pass the stack name explicitly. The script displays the stack ARN, checks the lab tag, and requests the stack name a second time before deletion.

```bash
bash infra/cleanup.sh rag-week2-lab
```

For a local workstation, use Bash, Docker Engine, jq and AWS CLI v2. Select a configured personal lab profile locally (`export AWS_PROFILE=your-lab-profile`) and run the same steps. The deploying identity needs access to provision the CloudFormation resources, create IAM roles and pass them to ECS, push images to ECR, upload the sample to S3, inspect the subnet, run an ECS task and read its CloudWatch logs.

See the AWS documentation for [Fargate task networking](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-networking.html), [task execution roles](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html), [task IAM roles](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html), and [CloudWatch logging](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_awslogs.html).
