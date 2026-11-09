-- 02: SKU -> category map. THE core anti-double-count control.
-- Seed with regex, then manually review every row (especially category = 'REVIEW')
-- and keep this table under change control keyed on sku_id.
CREATE OR REPLACE TABLE `${DS}.dto_sku_map` AS
SELECT DISTINCT
  sku.id          AS sku_id,
  sku.description AS sku,
  service.description AS service,
  CASE
    -- Cloud NAT charges: same bytes as the VM's internet egress (+ ingress). NEVER add to DTO.
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'cloud nat|nat gateway|nat data processing') THEN 'NAT_PROCESSING'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'cdn.*(cache )?(egress|data transfer)')     THEN 'INTERNET_DTO_CDN'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'internet (egress|data transfer out)')       THEN 'INTERNET_DTO'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'inter[ -]?region|inter[ -]?zone|intra[ -]?(zone|region)') THEN 'GCP_INTERNAL'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'interconnect|vpn|peering')                  THEN 'HYBRID'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'to google|google services')                 THEN 'GOOGLE_SERVICES'
    ELSE 'REVIEW'
  END AS category
FROM `${BILLING_TABLE}`
WHERE DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
  AND REGEXP_CONTAINS(LOWER(sku.description), r'egress|data transfer|\bnat\b');

-- Review:
-- SELECT category, sku_id, sku, service FROM `${DS}.dto_sku_map` ORDER BY category, sku;
-- Fix individually:
-- UPDATE `${DS}.dto_sku_map` SET category = 'INTERNET_DTO' WHERE sku_id = 'XXXX-XXXX-XXXX';
