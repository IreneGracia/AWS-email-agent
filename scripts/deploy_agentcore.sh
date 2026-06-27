#!/usr/bin/env bash
# Deploys BOTH Strands agents (Waiver Processor and Email Router) to Amazon
# Bedrock AgentCore Runtime using the bedrock-agentcore starter toolkit
# (direct_code_deploy — ARM64 deps cross-compiled in the cloud, no local Docker).
#
# Order matters: the waiver agent is deployed first, then the router (which is
# given the waiver runtime ARN so it delegates to the waiver agent on AgentCore).
#
# Why an isolated build dir per agent: the toolkit's dependency builder otherwise
# picks up the project-root requirements.txt (aws-cdk-lib) instead of the agent's
# deps, so we stage just the agent code + a minimal requirements.txt elsewhere.
#
# After this runs: put the two printed ARNs into cdk.json
# (waiver_agent_runtime_arn, router_agent_runtime_arn), then
# `cdk deploy InfraStack AgentStack` so ingestion -> router -> waiver all use AgentCore.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-eu-west-1}"
export AGENTCORE_SUPPRESS_RECOMMENDATION=1 AWS_REGION="$REGION"

acct="$(aws sts get-caller-identity --query Account --output text)"
criteria_bucket="$(aws cloudformation describe-stacks --stack-name InfraStack --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='WaiverCriteriaBucketName'].OutputValue" --output text)"
raw_bucket="$(aws cloudformation describe-stacks --stack-name InfraStack --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RawEmailsBucketName'].OutputValue" --output text)"
rag_arn="$(aws cloudformation describe-stacks --stack-name RagStack --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RagLambdaArn'].OutputValue" --output text)"
guardrail_id="$(aws cloudformation describe-stacks --stack-name AgentStack --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='GuardrailId'].OutputValue" --output text)"
email_from="$(python3 -c "import json;print(json.load(open('$ROOT/cdk.json'))['context']['email_from'])")"

# deploy_agent <name> <src-subdir> <env-flags...>  -> echoes the runtime ARN
deploy_agent() {
  local name="$1" src="$2"; shift 2
  local build; build="$(mktemp -d)/$name"
  mkdir -p "$build"
  cp "$ROOT/lambdas/agents/$src"/runtime_app.py "$ROOT/lambdas/agents/$src"/*.py "$build/" 2>/dev/null || true
  printf 'strands-agents>=0.1.0\nbedrock-agentcore>=1.0.0\n' > "$build/requirements.txt"
  ( cd "$build"
    agentcore configure -ni -r "$REGION" -dt direct_code_deploy -e runtime_app.py -n "$name" -rf requirements.txt -do -dm >&2
    agentcore deploy -a "$name" --force-rebuild-deps -auc "$@" >&2
  )
  grep -E 'agent_arn:' "$build/.bedrock_agentcore.yaml" | head -1 | awk '{print $2}'
  # stash the exec role for the caller to read
  ROLE_ARN="$(grep -E 'execution_role:' "$build/.bedrock_agentcore.yaml" | grep -v null | head -1 | awk '{print $2}')"
}

attach_policy() {  # <role-name> <policy-name> <template-json>
  sed -e "s/\${ACCT}/$acct/g" -e "s/\${REGION}/$REGION/g" \
      -e "s/\${CRITERIA_BUCKET}/$criteria_bucket/g" -e "s/\${RAW_EMAILS_BUCKET}/$raw_bucket/g" \
      -e "s/\${GUARDRAIL_ID}/$guardrail_id/g" "$3" > /tmp/_acpol.json
  aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document file:///tmp/_acpol.json --region "$REGION"
}

echo ">> Deploying waiver agent..."
WAIVER_ARN="$(deploy_agent waiveragent waiver \
  --env "EMAIL_FROM=$email_from" \
  --env "WAIVER_CRITERIA_BUCKET=$criteria_bucket" \
  --env "START_WAIVER_LAMBDA_ARN=arn:aws:lambda:${REGION}:${acct}:function:waiver-start-workflow" \
  --env "UPDATE_WAIVER_LAMBDA_ARN=arn:aws:lambda:${REGION}:${acct}:function:waiver-update-state" \
  --env "GET_WAIVER_LAMBDA_ARN=arn:aws:lambda:${REGION}:${acct}:function:waiver-get-state" \
  --env "GUARDRAIL_ID=${guardrail_id}" --env "GUARDRAIL_VERSION=DRAFT")"
attach_policy "${ROLE_ARN##*role/}" WaiverAgentCoreToolAccess "$ROOT/scripts/agentcore_exec_policy.json"

echo ">> Deploying router agent (delegates to waiver on AgentCore)..."
ROUTER_ARN="$(deploy_agent routeragent router \
  --env "EMAIL_FROM=$email_from" \
  --env "RAG_LAMBDA_ARN=$rag_arn" \
  --env "RAW_EMAILS_BUCKET=$raw_bucket" \
  --env "WAIVER_AGENT_RUNTIME_ARN=$WAIVER_ARN" \
  --env "GUARDRAIL_ID=${guardrail_id}" --env "GUARDRAIL_VERSION=DRAFT")"
attach_policy "${ROLE_ARN##*role/}" RouterAgentCoreToolAccess "$ROOT/scripts/agentcore_router_exec_policy.json"

echo
echo "Done. Put these in cdk.json context, then 'cdk deploy InfraStack AgentStack':"
echo "  waiver_agent_runtime_arn = $WAIVER_ARN"
echo "  router_agent_runtime_arn = $ROUTER_ARN"
