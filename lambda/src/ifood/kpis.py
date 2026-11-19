from __future__ import annotations

from datetime import date


def orders_kpis_body_order_status(*, gte: str, lte: str) -> dict:
    return {
        "filter": {"referenceDate": {"gte": gte, "lte": lte}},
        "agg": {
            "metrics": {"gmv": ["sum"]},
            "groupBy": {"fields": ["orderStatus"]},
        },
        "page": 1,
        "size": 50,
    }


def parse_order_status_counts(payload: dict) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in payload.get("data") or []:
        gb = item.get("groupByKey") or {}
        val = gb.get("value") or {}
        status = val.get("orderStatus")
        if status:
            counts[str(status)] = counts.get(str(status), 0) + int(gb.get("count") or 0)
            continue
        os_block = item.get("orderStatus")
        if isinstance(os_block, dict):
            inner = os_block.get("value")
            if isinstance(inner, dict):
                for k, v in inner.items():
                    counts[str(k)] = counts.get(str(k), 0) + int(v)
    return counts


def day_reference_bounds(day: date) -> tuple[str, str]:
    return f"{day.isoformat()} 00:00:00", f"{day.isoformat()} 23:59:59"


CANCELLATION_GROUP_FIELDS = (
    "cancellationCode",
    "cancellationOrigin",
    "cancellationReason",
    "cancellationStage",
)


def orders_kpis_body_cancellation(
    *,
    gte: str,
    lte: str,
    by_hour: bool,
    page: int = 1,
) -> dict:
    """Cancelled orders grouped by reason, origin, code and stage.

    ``by_hour`` adds ``orderCreationHour`` so the same day can feed the
    hourly charts. The Analytics API returns aggregates only.
    """
    fields = list(CANCELLATION_GROUP_FIELDS)
    if by_hour:
        fields.append("orderCreationHour")
    return {
        "filter": {
            "referenceDate": {"gte": gte, "lte": lte},
            "orderStatus": ["CANCELLED"],
        },
        "agg": {
            "metrics": {
                "gmv": ["sum"],
                "refundedTotalValue": ["sum"],
            },
            "groupBy": {"fields": fields},
        },
        "page": page,
        "size": 1000,
    }


def parse_grouped_kpis(payload: dict) -> list[dict]:
    rows: list[dict] = []
    for item in payload.get("data") or []:
        if not isinstance(item, dict):
            continue
        group = item.get("groupByKey") or {}
        value = group.get("value") or {}
        if not isinstance(value, dict):
            value = {}
        gmv = item.get("gmv") or {}
        refunded = item.get("refundedTotalValue") or {}
        rows.append(
            {
                "count": int(group.get("count") or 0),
                "cancellationCode": value.get("cancellationCode"),
                "cancellationOrigin": value.get("cancellationOrigin"),
                "cancellationReason": value.get("cancellationReason"),
                "cancellationStage": value.get("cancellationStage"),
                "orderCreationHour": value.get("orderCreationHour"),
                "gmv": gmv.get("sum") if isinstance(gmv, dict) else None,
                "refundedTotalValue": refunded.get("sum") if isinstance(refunded, dict) else None,
            }
        )
    return rows


def merge_kpi_pages(pages: list[dict]) -> dict:
    data: list = []
    for page in pages:
        data.extend(page.get("data") or [])
    first = pages[0] if pages else {}
    return {
        "data": data,
        "currentPage": 1,
        "totalPages": len(pages),
        "totalItems": first.get("totalItems"),
        "size": first.get("size"),
    }
