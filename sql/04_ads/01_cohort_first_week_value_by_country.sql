-- 국가, 플랫폼, 유입별 신규 코호트의 첫 7일 결제와 활동일. 광고 회수율을 계산할 재료다. (포트폴리오 1-4)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-10-06 ~ 2026-11-01, 코호트는 first_open이 10/6 ~ 10/25
--
-- 광고 시청 수익은 이 쿼리에 없다. ad_impression이 BigQuery로 넘어오지 않아서(1-1에서 찾은 설정 누락) 이렇게 추정했다.
--   두 번째 쿼리의 유저-일 합계로 AdMob 국가별 광고 수익을 나눠 ARPDAU를 구하고
--   첫 번째 쿼리의 첫 7일 활동일에 곱한다.
-- 포트폴리오의 회수율 표는 GA4 코호트 탐색의 유저당 누적 광고 수익을 Google Ads CPI로 나눠 만들었다.
-- 이 쿼리의 추정치는 그 숫자와 나라별 순위와 크기가 비슷한지 대조하는 데 썼다.
--
-- 유입: traffic_source.medium이 cpc면 paid. iOS는 ATT 때문에 대부분 unknown이라 유입을 나누지 않고 본다.
-- 결제: Android는 in_app_purchase, iOS는 purchase만 셌다. iOS 구독은 빠져 있어 결제 가치는 실제보다 낮게 나온다.
-- 활동일은 실사용 기준이 아니라 "이벤트가 있는 날"로 셌다. ARPDAU 분모와 정의가 같아야 곱셈이 맞는다.
-- 국가: ①은 first_open 시점의 geo.country, ②는 이벤트마다의 geo.country라 기준이 조금 다르다.

-- ① 신규 코호트 × 국가 × 유입별 첫 7일 가치 재료
WITH base AS (
  SELECT
    platform,
    user_pseudo_id,
    PARSE_DATE('%Y%m%d', event_date) AS d,
    event_name,
    event_value_in_usd,
    geo.country AS country,
    traffic_source.medium AS medium
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20261006' AND '20261101'
    AND platform IN ('IOS', 'ANDROID')
),
cohort AS (
  -- 유저별 첫 first_open 하나만
  SELECT platform, user_pseudo_id, day0, country, medium
  FROM (
    SELECT platform, user_pseudo_id, d AS day0, country, medium,
           ROW_NUMBER() OVER (PARTITION BY platform, user_pseudo_id ORDER BY d) AS rn
    FROM base
    WHERE event_name = 'first_open'
  )
  WHERE rn = 1
    AND day0 BETWEEN DATE '2026-10-06' AND DATE '2026-10-25'
),
users AS (
  SELECT
    c.platform,
    IF(c.country IN ('South Korea', 'United States', 'Japan', 'Thailand', 'France', 'Canada'), c.country, 'Other') AS country,
    CASE WHEN c.medium = 'cpc' THEN 'paid' WHEN c.medium = 'organic' THEN 'organic' ELSE 'unknown' END AS acquisition,
    c.user_pseudo_id,
    COUNT(DISTINCT IF(b.d BETWEEN c.day0 AND DATE_ADD(c.day0, INTERVAL 6 DAY), b.d, NULL)) AS active_days_7d,
    SUM(IF(b.d BETWEEN c.day0 AND DATE_ADD(c.day0, INTERVAL 6 DAY)
           AND ((c.platform = 'ANDROID' AND b.event_name = 'in_app_purchase')
             OR (c.platform = 'IOS' AND b.event_name = 'purchase')),
           b.event_value_in_usd, 0)) AS purchase_usd_7d
  FROM cohort c
  JOIN base b
    ON b.platform = c.platform AND b.user_pseudo_id = c.user_pseudo_id
  GROUP BY c.platform, country, acquisition, c.user_pseudo_id
)
SELECT
  platform,
  country,
  acquisition,
  COUNT(*) AS new_users,
  COUNTIF(purchase_usd_7d > 0) AS payers_7d,
  ROUND(SUM(purchase_usd_7d), 2) AS purchase_usd_7d,
  ROUND(AVG(active_days_7d), 2) AS avg_active_days_7d,
  SUM(active_days_7d) AS total_active_days_7d    -- × ARPDAU = 첫 7일 광고 수익 추정치
FROM users
GROUP BY platform, country, acquisition
ORDER BY platform, country, acquisition;

-- ② 국가 × 플랫폼별 유저-일 합계 (ARPDAU 분모). 같은 기간 AdMob 국가별 광고 수익으로 나눈다
SELECT
  platform,
  IF(geo.country IN ('South Korea', 'United States', 'Japan', 'Thailand', 'France', 'Canada'), geo.country, 'Other') AS country,
  COUNT(DISTINCT CONCAT(user_pseudo_id, '|', event_date)) AS user_days
FROM `your_project.analytics_000000.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20261006' AND '20261101'
  AND platform IN ('IOS', 'ANDROID')
GROUP BY platform, country
ORDER BY platform, user_days DESC;
