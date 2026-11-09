-- 04: Internet DTO by project / resource (VM, LB, bucket...).
-- Requires the DETAILED (resource-level) billing export.
-- Traffic egressing via Cloud NAT is billed to the originating VM, not to the NAT gateway.
SELECT
  FORMAT_TIMESTAMP('%Y-%m', b.usage_start_time) AS month,
  b.project.id                                  AS project_id,
  IFNULL(b.location.region, 'global/unknown')   AS src_region,
  b.service.description                         AS service,
  b.resource.name                               AS resource_name,
  b.resource.global_name                        AS resource_global_name,
  TO_JSON_STRING(ARRAY(SELECT AS STRUCT l.key, l.value FROM UNNEST(b.labels) l ORDER BY l.key)) AS labels,
  SUM(b.usage.amount_in_pricing_units)          AS gib,
  SUM(b.cost)                                   AS gross_cost,
  SUM(b.cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0)) AS net_cost
FROM `${BILLING_TABLE}` b
JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
WHERE m.category IN ('INTERNET_DTO', 'INTERNET_DTO_CDN')
  AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                 AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND b.usage_start_time >= TIMESTAMP('${START}')
  AND b.usage_start_time <  TIMESTAMP('${END}')
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY gib DESC;
