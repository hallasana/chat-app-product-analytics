-- 결제 이벤트가 purchase, in_app_purchase 두 종류로 들어온다. 같은 결제를 두 번 세고 있는지 확인한다. (포트폴리오 1-1)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-09-01 ~ 2026-10-31
--
-- purchase는 앱이 직접 보내서 거래 ID가 있고, in_app_purchase는 Firebase가 스토어 영수증으로 자동 수집해서 거래 ID가 없다.
-- 거래 ID로는 둘을 연결할 수 없어서 "같은 유저 + 같은 상품 + 10분 이내"를 같은 결제로 봤다.
--   10분: 영수증 검증과 클라이언트 이벤트 사이 지연이 길어야 몇 분이고 같은 상품을 10분 안에 두 번 사는 일은 거의 없다.
--   같은 상품: 처음에는 이 조건이 없었는데, 구독 결제가 몇 분 뒤에 산 소액 결제와 잘못 짝지어져서 추가했다.
--   후보가 여럿이면 시간 차가 가장 작은 것 하나만 짝으로 본다.
-- 두 번째 쿼리는 purchase 안에서 같은 거래 ID가 두 번 찍힌 건수를 센다.
--
-- 이 결과로 정한 매출 집계 기준
--   Android: in_app_purchase만 센다. purchase를 같이 세면 단건 결제가 두 번 잡힌다.
--   iOS: purchase + in_app_purchase 중 구독(subscription = 1). purchase는 단건만, in_app_purchase는 구독만 잡아서 겹치지 않는다.

-- ① 두 이벤트 사이의 겹침: in_app_purchase 1건마다 10분 안·같은 상품의 purchase 후보를 붙이고 가장 가까운 것만 남긴다
WITH iap AS (
  SELECT
    platform,
    user_pseudo_id,
    event_timestamp AS ts,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'product_id') AS product_id,
    COALESCE((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'subscription'), 0) = 1 AS is_sub,
    event_value_in_usd AS usd
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260901' AND '20261031'
    AND platform IN ('IOS', 'ANDROID')
    AND event_name = 'in_app_purchase'
),
pur AS (
  SELECT
    platform,
    user_pseudo_id,
    event_timestamp AS ts,
    ecommerce.transaction_id AS tid,
    items[SAFE_OFFSET(0)].item_id AS item_id,
    event_value_in_usd AS usd
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260901' AND '20261031'
    AND platform IN ('IOS', 'ANDROID')
    AND event_name = 'purchase'
),
pairs AS (
  SELECT
    i.platform, i.user_pseudo_id, i.ts AS iap_ts, i.is_sub, i.product_id, i.usd AS iap_usd,
    p.tid, p.item_id, p.usd AS pur_usd,
    ABS(i.ts - p.ts) / 1e6 AS gap_sec,
    -- in_app_purchase 1건당 가장 가까운 purchase 하나만 짝으로
    ROW_NUMBER() OVER (PARTITION BY i.platform, i.user_pseudo_id, i.ts ORDER BY ABS(i.ts - p.ts)) AS rn
  FROM iap i
  JOIN pur p
    ON p.platform = i.platform
   AND p.user_pseudo_id = i.user_pseudo_id
   AND ABS(i.ts - p.ts) <= 600 * 1000000   -- 10분 (event_timestamp는 마이크로초)
   AND i.product_id = p.item_id            -- 같은 상품이어야 짝으로 본다
),
matched AS (
  SELECT * FROM pairs WHERE rn = 1
)
-- in_app_purchase 쪽: 구독/단건별로 몇 건이 purchase와 짝이 있나
SELECT
  'in_app_purchase' AS side,
  i.platform,
  IF(i.is_sub, 'subscription', 'one_time') AS kind,
  COUNT(*) AS events,
  COUNTIF(m.tid IS NOT NULL) AS matched,
  ROUND(MAX(m.gap_sec), 1) AS max_gap_sec,
  COUNTIF(m.tid IS NOT NULL AND ABS(m.iap_usd - m.pur_usd) < 0.01) AS same_amount,
  STRING_AGG(DISTINCT IF(m.tid IS NOT NULL, CONCAT(m.product_id, ' <-> ', m.item_id), NULL), ' | ') AS product_pairs
FROM iap i
LEFT JOIN matched m
  ON m.platform = i.platform AND m.user_pseudo_id = i.user_pseudo_id AND m.iap_ts = i.ts
GROUP BY i.platform, kind

UNION ALL

-- purchase 쪽: 몇 건이 in_app_purchase와 짝이 있나. 짝 없는 purchase = in_app_purchase가 놓친 결제
SELECT
  'purchase' AS side,
  p.platform,
  '-' AS kind,
  COUNT(*) AS events,
  COUNTIF(EXISTS (
    SELECT 1 FROM matched m
    WHERE m.platform = p.platform AND m.user_pseudo_id = p.user_pseudo_id AND m.tid = p.tid
  )) AS matched,
  NULL AS max_gap_sec,
  NULL AS same_amount,
  NULL AS product_pairs
FROM pur p
GROUP BY p.platform
ORDER BY platform, side, kind;

-- ② purchase 안의 중복: 건수 > 거래 ID 고유 수이면 그 차이만큼 같은 거래가 두 번 기록된 것
SELECT
  platform,
  COUNT(*) AS events,
  COUNT(DISTINCT ecommerce.transaction_id) AS unique_transactions,
  COUNT(*) - COUNT(DISTINCT ecommerce.transaction_id) AS duplicate_rows
FROM `your_project.analytics_000000.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20260901' AND '20261031'
  AND platform IN ('IOS', 'ANDROID')
  AND event_name = 'purchase'
GROUP BY platform
ORDER BY platform;
