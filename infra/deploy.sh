#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION to the intended lab region}"
: "${SUBNET_ID:?Set SUBNET_ID to an existing public IPv4 subnet in the lab account}"
export AWS_PAGER=""
stack="${STACK_NAME:-rag-week2-lab}"
root=$(cd "$(dirname "$0")/.." && pwd)
[[ "$stack" =~ ^rag-week2-lab(-[a-z0-9-]+)?$ && ${#stack} -le 50 ]] || { echo "Use rag-week2-lab or rag-week2-lab-<suffix> (max 50 chars)." >&2; exit 2; }

awsr() { aws --region "$AWS_REGION" "$@"; }
account=$(awsr sts get-caller-identity --query Account --output text)
printf 'Target account %s, region %s, stack %s\n' "$account" "$AWS_REGION" "$stack"
vpc=$(awsr ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
tables=$(awsr ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET_ID" --output json)
if ! jq -e '.RouteTables | length > 0' <<< "$tables" >/dev/null; then
  tables=$(awsr ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" Name=association.main,Values=true --output json)
fi
if ! jq -e 'any(.RouteTables[].Routes[]; .DestinationCidrBlock == "0.0.0.0/0" and .State == "active" and ((.GatewayId // "") | startswith("igw-")))' <<< "$tables" >/dev/null; then
  echo "This subnet needs an active IPv4 default route to an internet gateway." >&2
  exit 2
fi

# Only update stacks created by this lab.
if previous=$(awsr cloudformation describe-stacks --stack-name "$stack" --output json 2>&1); then
  jq -e 'any(.Stacks[0].Tags[]?; .Key == "CourseLab" and .Value == "RagWeek2")' <<< "$previous" >/dev/null || { echo "Existing stack belongs to another project." >&2; exit 2; }
elif [[ "$previous" != *"does not exist"* ]]; then
  echo "$previous" >&2
  exit 1
fi

work=$(mktemp -d)
# Only the files created in this private temporary directory are removed.
trap 'rm -f "$work/image-id" "$work/config.json" "$work/log-error"; rmdir "$work" 2>/dev/null || true' EXIT
BUILDX_NO_DEFAULT_ATTESTATIONS=1 docker build --platform linux/amd64 --iidfile "$work/image-id" "$root"
image_id=$(cat "$work/image-id")
if ! docker image inspect "$image_id" >/dev/null; then
  echo "Select Docker's default local builder and rerun the script." >&2
  exit 1
fi
tag="w2-${image_id#sha256:}"
awsr cloudformation deploy --stack-name "$stack" --template-file "$root/infra/lab.yaml" \
  --capabilities CAPABILITY_IAM --tags CourseLab=RagWeek2 \
  --parameter-overrides "VpcId=$vpc" "ImageTag=$tag" --no-fail-on-empty-changeset
details=$(awsr cloudformation describe-stacks --stack-name "$stack" --output json)
output() { jq -er --arg k "$1" '.Stacks[0].Outputs[] | select(.OutputKey == $k) | .OutputValue' <<< "$details"; }
repo=$(output Repository)
bucket=$(output Bucket)
cluster=$(output Cluster)
task_def=$(output TaskDefinition)
group=$(output SecurityGroup)
log_group=$(output LogGroup)

images=$(awsr ecr list-images --repository-name "${repo#*/}" --filter tagStatus=TAGGED --output json)
if ! jq -e --arg tag "$tag" 'any(.imageIds[]; .imageTag == $tag)' <<< "$images" >/dev/null; then
  # Pass a short-lived ECR password via stdin and isolate Docker's registry config.
  awsr ecr get-login-password | docker --config "$work" login --username AWS --password-stdin "${repo%%/*}"
  docker tag "$image_id" "$repo:$tag"
  docker --config "$work" push "$repo:$tag"
fi
awsr s3api put-object --bucket "$bucket" --key week2/sample.json --body "$root/data/sample.json" --content-type application/json >/dev/null
run=$(awsr ecs run-task --cluster "$cluster" --task-definition "$task_def" --launch-type FARGATE --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$group],assignPublicIp=ENABLED}" --output json)
if ! task=$(jq -er '.tasks[0].taskArn' <<< "$run"); then
  jq '.failures' <<< "$run" >&2
  exit 1
fi
id="${task##*/}"
printf 'Fargate task %s\n' "$id"
awsr ecs wait tasks-stopped --cluster "$cluster" --tasks "$task"
state=$(awsr ecs describe-tasks --cluster "$cluster" --tasks "$task" --output json)
jq -r '.tasks[0] | "State: \(.lastStatus) | Exit: \(.containers[0].exitCode) | Reason: \(.stoppedReason)", (.containers[0].reason // empty)' <<< "$state"
stream="lab/api/$id"
printf 'CloudWatch group: %s\nLog stream: %s\n' "$log_group" "$stream"
logs=''
for ((attempt=1; attempt<=12; attempt++)); do
  if page=$(awsr logs get-log-events --log-group-name "$log_group" --log-stream-name "$stream" --start-from-head --no-paginate --output json 2>"$work/log-error"); then
    logs=$(jq -r '.events[].message' <<< "$page")
    [[ "$logs" == *"SMOKE TEST PASSED"* ]] && break
  fi
  sleep 2
done
cat "$work/log-error" >&2
rm -f "$work/log-error"
printf '%s\n' "$logs"
jq -e '.tasks[0].containers[0].exitCode == 0' <<< "$state" >/dev/null
[[ "$logs" == *"SMOKE TEST PASSED"* ]] || { echo "Success marker not found. Inspect the log stream above." >&2; exit 1; }
