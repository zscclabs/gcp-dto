-- 06: One row per month / project / region with DTO and NAT side by side.
-- dto_* = billed internet egress (already includes traffic that left via Cloud NAT).
-- nat_* = Cloud NAT charges (processing GiB covers egress + ingress, uptime is hours).
-- total_cost = DTO cost + NAT cost. Costs add; GiB do NOT (nat_processed_gib re-describes DTO bytes).
WITH base AS (
  SELECT
    FORMAT_TIMESTAMP('%Y-%m', b.usage_start_time)  AS month,
    b.project.id                                   AS project_id,
    IFNULL(b.location.region, 'global/unknown')    AS region,
    m.category,
    b.sku.description                              AS sku,
    b.usage.pricing_unit                           AS unit,
    b.usage.amount_in_pricing_units                AS qty,
    b.cost                                         AS cost,
    b.cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0) AS net_cost
  FROM `${BILLING_TABLE}` b
  JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
  WHERE m.category IN ('INTERNET_DTO', 'NAT_PROCESSING')   -- add 'INTERNET_DTO_CDN' if CDN counts as DTO for you
    AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                   AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
    AND b.usage_start_time >= TIMESTAMP('${START}')
    AND b.usage_start_time <  TIMESTAMP('${END}')
)
SELECT
  month, project_id, region,
  -- DTO (the only GiB you sum)
  SUM(IF(category = 'INTERNET_DTO', qty, 0))                                        AS dto_gib,
  SUM(IF(category = 'INTERNET_DTO', cost, 0))                                       AS dto_gross_cost,
  SUM(IF(category = 'INTERNET_DTO', net_cost, 0))                                   AS dto_net_cost,
  -- NAT (reported separately)
  SUM(IF(category = 'NAT_PROCESSING' AND unit = 'gibibyte', qty, 0))                AS nat_processed_gib,
  SUM(IF(category = 'NAT_PROCESSING' AND unit = 'gibibyte', cost, 0))               AS nat_processing_cost,
  SUM(IF(category = 'NAT_PROCESSING' AND unit != 'gibibyte', qty, 0))               AS nat_gateway_hours,
  SUM(IF(category = 'NAT_PROCESSING' AND unit != 'gibibyte', cost, 0))              AS nat_uptime_cost,
  SUM(IF(category = 'NAT_PROCESSING', net_cost, 0))                                 AS nat_net_cost,
  -- Combined cost (valid: different charges). Do NOT add dto_gib + nat_processed_gib.
  SUM(net_cost)                                                                     AS total_net_cost
FROM base
GROUP BY 1, 2, 3
ORDER BY month, total_net_cost DESC;
