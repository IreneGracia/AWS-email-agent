import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_region  = os.environ.get("AWS_REGION", "eu-west-1")
dynamodb = boto3.resource("dynamodb", region_name=_region)


def handler(event, context):
    waiver_id = event.get("waiver_id")
    if not waiver_id:
        return {"error": "waiver_id is required"}

    table = dynamodb.Table(os.environ["WAIVER_TABLE"])
    try:
        resp = table.get_item(Key={"waiver_id": waiver_id})
        item = resp.get("Item")
        if not item:
            logger.warning("Waiver not found | waiver_id=%s", waiver_id)
            return {"error": f"Waiver '{waiver_id}' not found"}
        return dict(item)
    except Exception as e:
        logger.error("get_item failed: %s", e)
        return {"error": str(e)}