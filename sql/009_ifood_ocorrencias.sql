-- Cancelamento e chamado no grão do pedido, a partir do JSON já ingerido
-- (Financial Sales: orderEvents e orderStatusHistory).
-- impacto_super fica nulo: a API não expõe o flag do Portal de Redes.
-- Aplicar depois de 006.

CREATE OR REPLACE FUNCTION ifood_json_object(raw jsonb, key text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    value jsonb;
    kind text;
BEGIN
    IF raw IS NULL OR key IS NULL THEN
        RETURN NULL;
    END IF;
    value := raw -> key;
    kind := jsonb_typeof(value);
    IF kind = 'object' THEN
        RETURN value;
    ELSIF kind = 'string' THEN
        BEGIN
            RETURN (value #>> '{}')::jsonb;
        EXCEPTION WHEN others THEN
            RETURN NULL;
        END;
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE VIEW v_fato_ifood_pedido AS
WITH event_agg AS (
    SELECT
        e.order_id,
        COUNT(*)::int AS qtd_eventos,
        MAX(e.event_created_at) AS ultimo_evento_em,
        (ARRAY_AGG(e.full_code ORDER BY e.event_created_at DESC NULLS LAST))[1] AS ultimo_evento_full_code,
        (ARRAY_AGG(e.code ORDER BY e.event_created_at DESC NULLS LAST))[1] AS ultimo_evento_code
    FROM ifood_order_events e
    GROUP BY e.order_id
),
chamado_patterns AS (
    SELECT pattern FROM dim_ifood_evento_chamado WHERE ativo
),
pedidos_chamado AS (
    SELECT DISTINCT e.order_id
    FROM ifood_order_events e
    CROSS JOIN chamado_patterns p
    WHERE UPPER(COALESCE(e.full_code, '')) LIKE UPPER(p.pattern)
       OR UPPER(COALESCE(e.code, '')) LIKE UPPER(p.pattern)
),
review_one AS (
    SELECT DISTINCT ON (r.order_id)
        r.order_id,
        r.id AS review_id,
        r.rating,
        (COALESCE(r.comment, '') <> '') AS tem_comentario
    FROM ifood_reviews r
    WHERE r.order_id IS NOT NULL
    ORDER BY r.order_id, r.review_date DESC NULLS LAST, r.created_at DESC NULLS LAST
),
cancel_event AS (
    SELECT DISTINCT ON (e.order_id)
        e.order_id,
        ifood_json_object(e.raw_event, 'metadata') AS meta
    FROM ifood_order_events e
    WHERE e.full_code IN ('CANCELLED', 'CANCEL')
       OR e.code IN ('CAN', 'CANC')
    ORDER BY e.order_id, e.event_created_at DESC NULLS LAST
),
refund_event AS (
    SELECT DISTINCT ON (e.order_id)
        e.order_id,
        ifood_json_object(e.raw_event, 'metadata') AS meta
    FROM ifood_order_events e
    WHERE e.full_code = 'REFUND'
    ORDER BY e.order_id, e.event_created_at DESC NULLS LAST
),
status_cancel AS (
    SELECT DISTINCT ON (o.id)
        o.id AS order_id,
        ifood_json_object(h.elem, 'metadata') AS meta
    FROM ifood_orders o
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(o.raw_sale -> 'orderStatusHistory', '[]'::jsonb)
    ) AS h(elem)
    WHERE UPPER(COALESCE(h.elem ->> 'value', '')) LIKE '%CANCEL%'
    ORDER BY o.id, h.elem ->> 'createdAt' DESC NULLS LAST
),
dispute AS (
    SELECT DISTINCT ON (e.order_id)
        e.order_id,
        e.event_created_at AS chamado_em,
        ifood_json_object(e.raw_event, 'metadata') AS meta
    FROM ifood_order_events e
    WHERE e.full_code = 'HANDSHAKE_DISPUTE' OR e.code = 'HSD'
    ORDER BY e.order_id, e.event_created_at DESC NULLS LAST
),
settlement AS (
    SELECT DISTINCT ON (e.order_id)
        e.order_id,
        e.event_created_at AS resposta_em,
        ifood_json_object(e.raw_event, 'metadata') AS meta
    FROM ifood_order_events e
    WHERE e.full_code = 'HANDSHAKE_SETTLEMENT' OR e.code = 'HSS'
    ORDER BY e.order_id, e.event_created_at DESC NULLS LAST
)
SELECT
    o.id AS pedido_id,
    o.merchant_id,
    dl.id AS loja_id,
    COALESCE(dl.loja, o.merchant_name, o.merchant_id::text) AS loja_nome,
    o.sales_date,
    o.created_at,
    o.short_id,
    o.sales_channel AS canal,
    o.order_type AS tipo,
    o.category AS categoria,
    o.current_status AS status_atual,
    o.sale_balance AS valor_venda,
    o.payment_total AS valor_pagamento,
    (UPPER(COALESCE(o.current_status, '')) LIKE '%CANCEL%') AS flag_cancelado,
    (UPPER(COALESCE(o.current_status, '')) LIKE '%CONCLUD%') AS flag_concluido,
    (pc.order_id IS NOT NULL) AS flag_chamado,
    COALESCE(ea.qtd_eventos, 0) AS qtd_eventos,
    ea.ultimo_evento_full_code,
    ea.ultimo_evento_code,
    ea.ultimo_evento_em,
    ro.review_id,
    ro.rating AS nota_review,
    COALESCE(ro.tem_comentario, FALSE) AS tem_comentario,
    o.ingested_at AS ingested_at_pedido,
    COALESCE(
        ce.meta ->> 'CANCEL_REASON',
        ce.meta ->> 'CANCEL_CODE_DESCRIPTION',
        sc.meta ->> 'CANCEL_REASON',
        sc.meta ->> 'cancellationReason'
    ) AS motivo_cancelamento,
    COALESCE(
        ce.meta ->> 'CANCEL_ORIGIN',
        sc.meta ->> 'CANCEL_ORIGIN',
        sc.meta ->> 'cancellationOrigin'
    ) AS origem_cancelamento,
    COALESCE(
        ce.meta ->> 'CANCEL_CODE',
        sc.meta ->> 'CANCEL_CODE',
        sc.meta ->> 'cancellationCode',
        rf.meta ->> 'cancelCode'
    ) AS codigo_cancelamento,
    COALESCE(ce.meta ->> 'CANCEL_STAGE', sc.meta ->> 'CANCEL_STAGE', sc.meta ->> 'cancellationStage') AS estagio_cancelamento,
    CASE d.meta ->> 'handshakeType'
        WHEN 'PREPARATION_TIME' THEN 'PREPARO'
        WHEN 'DELAY' THEN 'ATRASO NA ENTREGA'
        WHEN 'AFTER_DELIVERY' THEN 'APOS A ENTREGA'
        WHEN 'AFTER_DELIVERY_PARTIALLY' THEN 'APOS A ENTREGA'
        ELSE NULL
    END AS momento_chamado,
    d.meta ->> 'handshakeType' AS momento_chamado_api,
    CASE
        WHEN s.meta ->> 'status' = 'EXPIRED' THEN 'NÃO RESPONDEU'
        WHEN s.meta ->> 'status' = 'REJECTED' THEN 'RECUSOU A SOLICITAÇÃO'
        WHEN s.meta ->> 'status' = 'ACCEPTED' THEN 'PREFERIU CANCELAR O PEDIDO'
        WHEN s.meta ->> 'status' = 'ALTERNATIVE_REPLIED'
             AND s.meta #>> '{selectedDisputeAlternative,type}' = 'ADDITIONAL_TIME'
            THEN 'PROPÔS NEGOCIAÇÃO COM CLIENTE'
        WHEN s.meta ->> 'status' = 'ALTERNATIVE_REPLIED' THEN 'NEGOCIOU'
        ELSE NULL
    END AS resposta_loja_aproximada,
    s.meta ->> 'status' AS resposta_loja_status,
    d.meta ->> 'message' AS motivo_chamado,
    d.meta ->> 'action' AS acao_chamado,
    d.chamado_em,
    s.resposta_em,
    NULL::boolean AS impacto_super
FROM ifood_orders o
LEFT JOIN dim_lojas dl ON dl.merchant_id = o.merchant_id
LEFT JOIN event_agg ea ON ea.order_id = o.id
LEFT JOIN pedidos_chamado pc ON pc.order_id = o.id
LEFT JOIN review_one ro ON ro.order_id = o.id
LEFT JOIN cancel_event ce ON ce.order_id = o.id
LEFT JOIN refund_event rf ON rf.order_id = o.id
LEFT JOIN status_cancel sc ON sc.order_id = o.id
LEFT JOIN dispute d ON d.order_id = o.id
LEFT JOIN settlement s ON s.order_id = o.id;

-- Agregado D-1 do Analytics: motivo, origem, código e estágio.
-- request_kind orders_kpis_cancellation = o dia; orders_kpis_cancellation_hour = a hora.
CREATE OR REPLACE VIEW v_ifood_cancelamento_analytics AS
SELECT
    k.merchant_id,
    dl.id AS loja_id,
    COALESCE(dl.loja, k.merchant_id::text) AS loja_nome,
    k.reference_date,
    CASE
        WHEN k.request_kind = 'orders_kpis_cancellation_hour'
            THEN NULLIF(row.elem ->> 'orderCreationHour', '')::int
        ELSE NULL
    END AS hora,
    row.elem ->> 'cancellationCode' AS codigo,
    row.elem ->> 'cancellationOrigin' AS origem,
    row.elem ->> 'cancellationReason' AS motivo,
    row.elem ->> 'cancellationStage' AS estagio,
    NULLIF(row.elem ->> 'count', '')::int AS pedidos,
    NULLIF(row.elem ->> 'gmv', '')::numeric AS gmv,
    NULLIF(row.elem ->> 'refundedTotalValue', '')::numeric AS valor_estornado,
    k.request_kind
FROM ifood_analytics_kpi_daily k
CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(k.status_counts -> 'rows', '[]'::jsonb)
) AS row(elem)
LEFT JOIN dim_lojas dl ON dl.merchant_id = k.merchant_id
WHERE k.request_kind IN ('orders_kpis_cancellation', 'orders_kpis_cancellation_hour');
