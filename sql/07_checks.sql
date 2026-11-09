-- 07: Billing-only integrity checks.

-- 7a. Unmapped SKUs: egress, data transfer or NAT SKUs in the period that are missing from dto_sku_map.
--     Any row here means the map is stale and DTO/NAT may be understated. Add them to 02 and re-run.
SELECT b.sku.id AS sku_id, b.sku.description AS sku, b.service.description AS service,
       SUM(b.usage.amount_in_pricing_units) AS qty, SUM(b.cost) AS cost
FROM `${BILLING_TABLE}` b
LEFT JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
WHERE m.sku_id IS NULL
  AND REGEXP_CONTAINS(LOWER(b.sku.description), r'egress|data transfer|\bnat\b')
  AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                 AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND b.usage_start_time >= TIMESTAMP('${START}') AND b.usage_start_time < TIMESTAMP('${END}')
GROUP BY 1, 2, 3
ORDER BY cost DESC;

-- 7b. Each SKU maps to exactly one category. A SKU that maps to more than one gets counted twice. Expect 0 rows.
SELECT sku_id, COUNT(DISTINCT category) AS n_categories, STRING_AGG(DISTINCT category) AS categories
FROM `${DS}.dto_sku_map`
GROUP BY sku_id
HAVING COUNT(*) > 1;

-- 7c. Anything still marked REVIEW. Expect 0 rows.
SELECT * FROM `${DS}.dto_sku_map` WHERE category = 'REVIEW';

-- 7d. Totals: compare dto_gross_cost and nat_gross_cost with the Cloud Billing console report for the same SKUs and period.
SELECT
  m.category,
  SUM(b.usage.amount_in_pricing_units) AS qty,
  SUM(b.cost)                          AS gross_cost
FROM `${BILLING_TABLE}` b
JOIN `${DS}.dto_sku_map` m ON m.sku_id = b.sku.id
WHERE m.category IN ('INTERNET_DTO', 'INTERNET_DTO_CDN', 'NAT_PROCESSING')
  AND DATE(b._PARTITIONTIME) BETWEEN DATE_SUB(DATE '${START}', INTERVAL 5 DAY)
                                 AND DATE_ADD(DATE '${END}', INTERVAL 5 DAY)
  AND b.usage_start_time >= TIMESTAMP('${START}') AND b.usage_start_time < TIMESTAMP('${END}')
GROUP BY 1;
