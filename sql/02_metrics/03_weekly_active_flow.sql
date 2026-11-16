-- 주간 활성 유저(WAU)가 왜 늘고 줄었는지 보려고 신규, 유지, 복귀, 이탈로 나눈다. (포트폴리오 1-2)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-08-25 ~ 2026-11-01, 결과는 9/7 주부터 10/26 주까지
--
-- 이번 주 WAU = 지난주 WAU + 신규 + 복귀 - 이탈
--   신규: 이번 주 활성이고 first_open이 이번 주
--   유지: 이번 주 활성이고 지난주에도 활성
--   복귀: 이번 주 활성, 지난주 비활성, 신규 아님
--   이탈: 지난주 활성인데 이번 주 비활성 (이번 주 행에 표시)
-- 설치한 주에 활성인 유저는 신규로 먼저 센다.
-- quick_ratio = (신규 + 복귀) / 이탈, retained_pct = 유지 / 지난주 WAU
-- 9/7 주부터 보는 이유: export가 8/25에 시작돼 첫 두 주는 지난주 기록이 없다.
-- 8/25 전에 설치한 유저는 first_open이 없어 신규로 잡히지 않는다. 그래서 9월 초 복귀가 조금 많게 나온다.
-- 끝난 주만 낸다.

WITH ev AS (
  SELECT
    platform,
    user_pseudo_id,
    PARSE_DATE('%Y%m%d', event_date) AS d,
    event_name
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260825' AND '20261101'
    AND platform IN ('IOS', 'ANDROID')
    AND event_name IN ('first_open', 'user_engagement', 'session_start')
),
params AS (
  SELECT DATE '2026-10-26' AS last_full_week   -- 마지막으로 끝난 주의 월요일 (10/26 ~ 11/1)
),
first_open AS (
  SELECT platform, user_pseudo_id, DATE_TRUNC(MIN(d), WEEK(MONDAY)) AS install_week
  FROM ev
  WHERE event_name = 'first_open'
  GROUP BY platform, user_pseudo_id
),
active_weeks AS (
  -- 유저 × 활성 주 (한 주에 여러 날 와도 1행)
  SELECT DISTINCT platform, user_pseudo_id, DATE_TRUNC(d, WEEK(MONDAY)) AS w
  FROM ev
  WHERE event_name IN ('user_engagement', 'session_start')
),
status AS (
  -- 이번 주 활성 유저를 신규 / 유지 / 복귀로 분류
  SELECT
    a.platform, a.w, a.user_pseudo_id,
    CASE
      WHEN f.install_week = a.w THEN 'new'
      WHEN p.user_pseudo_id IS NOT NULL THEN 'retained'
      ELSE 'resurrected'
    END AS st
  FROM active_weeks a
  LEFT JOIN first_open f USING (platform, user_pseudo_id)
  LEFT JOIN active_weeks p
    ON p.platform = a.platform AND p.user_pseudo_id = a.user_pseudo_id
   AND p.w = DATE_SUB(a.w, INTERVAL 7 DAY)

  UNION ALL

  -- 지난주 활성이었는데 이번 주 안 온 유저 = 이번 주 이탈
  SELECT p.platform, DATE_ADD(p.w, INTERVAL 7 DAY) AS w, p.user_pseudo_id, 'churned' AS st
  FROM active_weeks p
  LEFT JOIN active_weeks a
    ON a.platform = p.platform AND a.user_pseudo_id = p.user_pseudo_id
   AND a.w = DATE_ADD(p.w, INTERVAL 7 DAY)
  WHERE a.user_pseudo_id IS NULL
),
weekly AS (
  SELECT
    s.w,
    s.platform,
    COUNTIF(s.st != 'churned') AS wau,
    COUNTIF(s.st = 'new') AS new_users,
    COUNTIF(s.st = 'retained') AS retained,
    COUNTIF(s.st = 'resurrected') AS resurrected,
    COUNTIF(s.st = 'churned') AS churned
  FROM status s
  CROSS JOIN params
  WHERE s.w BETWEEN DATE '2026-09-07' AND params.last_full_week
  GROUP BY GROUPING SETS ((s.w, s.platform), (s.w))
)
SELECT
  w AS week,
  IFNULL(platform, 'ALL') AS platform_label,
  wau,
  new_users,
  retained,
  resurrected,
  churned,
  new_users + resurrected - churned AS net_change,
  ROUND((new_users + resurrected) / NULLIF(churned, 0), 2) AS quick_ratio,
  ROUND(100 * retained / NULLIF(retained + churned, 0), 1) AS retained_pct   -- 지난주 WAU = 유지 + 이탈
FROM weekly
ORDER BY week, platform_label;
