import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_region  = os.environ.get("AWS_REGION", "eu-west-1")
dynamodb = boto3.resource("dynamodb", region_name=_region)


def _now():
    return datetime.now(timezone.utc).isoformat()


def handler(event, context):
    waiver_id      = event.get("waiver_id")
    new_info       = event.get("new_info", {})
    missing_fields = event.get("missing_fields", [])

    if not waiver_id:
        return {"success": False, "error": "waiver_id is required"}

    table = dynamodb.Table(os.environ["WAIVER_TABLE"])
    now   = _now()

    try:
        resp          = table.get_item(Key={"waiver_id": waiver_id})
        existing_info = resp.get("Item", {}).get("collected_info", {})
    except Exception as e:
        return {"success": False, "error": str(e)}

    merged_info = {**existing_info, **new_info}
    new_status  = "pending_info" if missing_fields else "pending_approval"

    try:
        table.update_item(
            Key={"waiver_id": waiver_id},
            UpdateExpression=(
                "SET collected_info = :ci, missing_fields = :mf, "
                "#st = :st, updated_at = :ts, "
                "history = list_append(if_not_exists(history, :empty), :h)"
            ),
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":ci":    merged_info,
                ":mf":    missing_fields,
                ":st":    new_status,
                ":ts":    now,
                ":h": [{
                    "timestamp": now,
                    "event":     "info_updated",
                    "content": (
                        f"Updated fields: {list(new_info.keys())}. "
                        f"Still missing: {missing_fields or 'nothing'}."
                    ),
                }],
                ":empty": [],
            },
        )
        logger.info("Waiver updated | waiver_id=%s | status=%s", waiver_id, new_status)
        return {"success": True, "waiver_id": waiver_id, "status": new_status}
    except Exception as e:
        logger.error("update_item failed: %s", e)
        return {"success": False, "error": str(e)}