-- 01: SKU discovery. Run first; SKU names changed over time ("Egress" -> "Data Transfer").
-- Placeholders: ${BILLING_TABLE} = proj.ds.gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX
--               ${START}, ${END} = 'YYYY-MM-DD' (END exclusive)
SELECT
  service.description               AS service,
  sku.id                            AS sku_id,
  sku.description                   AS sku,
  usage.pricing_unit,
  SUM(usage.amount_in_pricing_units) AS qty,
  ROUND(SUM(cost), 2)                AS cost
FROM `${BILLING_TABLE}`
WHERE DATE(_PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                               AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND usage_start_time >= TIMESTAMP('${START}')
  AND usage_start_time <  TIMESTAMP('${END}')
  AND REGEXP_CONTAINS(LOWER(sku.description), r'egress|data transfer|\bnat\b')
GROUP BY 1, 2, 3, 4
ORDER BY cost DESC;
