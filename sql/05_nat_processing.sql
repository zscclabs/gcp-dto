-- 05: Cloud NAT charges, reported SEPARATELY. Never add this GiB to DTO:
--   * Data Processing GiB = egress + ingress bytes through NAT (the egress part is already in 03).
--   * Gateway uptime is hours, not bytes.
SELECT
  FORMAT_TIMESTAMP('%Y-%m', b.usage_start_time) AS month,
  b.project.id                                  AS project_id,
  IFNULL(b.location.region, 'global/unknown')   AS region,
  b.resource.name                               AS nat_resource,
  b.sku.description                             AS sku,
  b.usage.pricing_unit,
  SUM(b.usage.amount_in_pricing_units)          AS qty,
  SUM(b.cost)                                   AS gross_cost,
  SUM(b.cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0)) AS net_cost
FROM `${BILLING_TABLE}` b
JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
WHERE m.category = 'NAT_PROCESSING'
  AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                 AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND b.usage_start_time >= TIMESTAMP('${START}')
  AND b.usage_start_time <  TIMESTAMP('${END}')
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY gross_cost DESC;
