#!/usr/bin/env bash
set -euo pipefail
: "${AWS_REGION:?Set AWS_REGION to the lab region}"
export AWS_PAGER=""
stack="${1:?Usage: bash infra/cleanup.sh rag-week2-lab}"
[[ "$stack" =~ ^rag-week2-lab(-[a-z0-9-]+)?$ && ${#stack} -le 50 ]] || { echo "Invalid lab stack name." >&2; exit 2; }
awsr() { aws --region "$AWS_REGION" "$@"; }
details=$(awsr cloudformation describe-stacks --stack-name "$stack" --output json)
jq -e 'any(.Stacks[0].Tags[]?; .Key == "CourseLab" and .Value == "RagWeek2")' <<< "$details" >/dev/null || { echo "Not a tagged week 2 stack." >&2; exit 2; }
stack_id=$(jq -er '.Stacks[0].StackId' <<< "$details")
output() { jq -r --arg k "$1" 'first(.Stacks[0].Outputs[]? | select(.OutputKey == $k) | .OutputValue) // empty' <<< "$details"; }
bucket=$(output Bucket)
repo=$(output Repository)
cluster=$(output Cluster)
if [[ -n "$cluster" ]]; then
  tasks=$(awsr ecs list-tasks --cluster "$cluster" --desired-status RUNNING --output json)
  jq -e '.taskArns | length == 0' <<< "$tasks" >/dev/null || { echo "Wait for all lab tasks to stop before cleanup." >&2; exit 2; }
fi
if [[ -n "$repo" ]]; then
  images=$(awsr ecr list-images --repository-name "${repo#*/}" --output json)
  jq -e 'all(.imageIds[]; (.imageTag // "") | test("^w2-[a-f0-9]{64}$"))' <<< "$images" >/dev/null || { echo "Unexpected images in the lab repository. Inspect them before deletion." >&2; exit 2; }
fi
if [[ -n "$bucket" ]]; then
  contents=$(awsr s3api list-objects-v2 --bucket "$bucket" --output json)
  jq -e 'all(.Contents[]?; .Key == "week2/sample.json")' <<< "$contents" >/dev/null || { echo "Bucket contains other objects. Inspect them before deletion." >&2; exit 2; }
fi
printf 'This deletes the lab stack, sample object, images, and CloudWatch evidence.\n%s\nType the stack name to confirm: ' "$stack_id"
read -r confirmation
[[ "$confirmation" == "$stack" ]] || { echo "Cancelled."; exit 2; }
if [[ -n "$bucket" ]]; then
  awsr s3api delete-object --bucket "$bucket" --key week2/sample.json >/dev/null
fi
awsr cloudformation delete-stack --stack-name "$stack_id"
awsr cloudformation wait stack-delete-complete --stack-name "$stack_id"
echo "Lab stack deleted."
