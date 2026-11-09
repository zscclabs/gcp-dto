-- 03: Headline internet DTO by month / source region / destination geo.
-- NAT_PROCESSING is excluded on purpose: NAT'd egress is already billed here, to the VM.
SELECT
  FORMAT_TIMESTAMP('%Y-%m', b.usage_start_time)                         AS month,
  IFNULL(b.location.region, 'global/unknown')                           AS src_region,
  REGEXP_EXTRACT(b.sku.description, r'(?i) to ([A-Za-z &]+?)(?:\s*\(|$)') AS dest_geo,
  m.category,
  b.usage.pricing_unit,                                                  -- expect 'gibibyte'
  SUM(b.usage.amount_in_pricing_units)                                   AS gib,
  SUM(b.cost)                                                            AS gross_cost,
  SUM(b.cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0)) AS net_cost
FROM `${BILLING_TABLE}` b
JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
WHERE m.category IN ('INTERNET_DTO', 'INTERNET_DTO_CDN')
  AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                 AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND b.usage_start_time >= TIMESTAMP('${START}')
  AND b.usage_start_time <  TIMESTAMP('${END}')
GROUP BY 1, 2, 3, 4, 5
ORDER BY gib DESC;
