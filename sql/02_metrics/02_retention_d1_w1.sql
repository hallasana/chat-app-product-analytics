-- 주별 신규 코호트의 D1, W1, W2 리텐션. 광고 설정을 바꾸기 전 기준선으로 썼다. (포트폴리오 1-2)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-08-25 ~ 2026-11-01
--
-- 신규 = 유저별 가장 이른 first_open 날짜. 코호트는 그 날짜가 속한 주(월요일 시작)다.
-- 활성 = user_engagement 또는 session_start (01_active_user_definition 기준).
-- D1은 설치 다음 날, W1은 1~7일째 중 하루라도, W2는 8~14일째 중 하루라도 활성.
-- D7(정확히 7일째)은 참고용이다. 하루 신규가 수십~백여 명이라 하루 기준은 너무 출렁이고
-- 매일 쓰는 앱이 아니라서 "그 주에 다시 왔나"가 더 맞는 질문이라고 봤다.
-- GA4 코호트 탐색의 주별 보기와 같은 방식이라 콘솔 숫자와 대조하기도 쉽다.
-- 관찰 기간이 끝나지 않은 코호트는 NULL로 둔다. 첫 주(8/24 주)는 export가 8/25에 시작돼 부분 주다.
-- 원래는 end_date를 어제로 두고 매주 돌렸고 여기서는 10월 말로 고정했다.

WITH params AS (
  SELECT DATE '2026-11-01' AS end_date   -- 마지막 export 날짜
),
ev AS (
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
cohort AS (
  SELECT platform, user_pseudo_id, MIN(d) AS day0
  FROM ev
  WHERE event_name = 'first_open'
  GROUP BY platform, user_pseudo_id
),
active_days AS (
  SELECT DISTINCT platform, user_pseudo_id, d
  FROM ev
  WHERE event_name IN ('user_engagement', 'session_start')
),
users AS (
  -- 유저 1명당 1행: Day0 기준 몇 일째에 활성이었나를 플래그로
  SELECT
    c.platform,
    c.user_pseudo_id,
    c.day0,
    COUNTIF(DATE_DIFF(a.d, c.day0, DAY) = 1) > 0 AS d1,
    COUNTIF(DATE_DIFF(a.d, c.day0, DAY) BETWEEN 1 AND 7) > 0 AS w1,
    COUNTIF(DATE_DIFF(a.d, c.day0, DAY) BETWEEN 8 AND 14) > 0 AS w2,
    COUNTIF(DATE_DIFF(a.d, c.day0, DAY) = 7) > 0 AS d7
  FROM cohort c
  LEFT JOIN active_days a USING (platform, user_pseudo_id)
  GROUP BY c.platform, c.user_pseudo_id, c.day0
)
SELECT
  DATE_TRUNC(day0, WEEK(MONDAY)) AS cohort_week,
  IFNULL(platform, 'ALL') AS platform_label,   -- 별칭을 platform으로 두면 GROUP BY가 별칭을 잡아 합계 행이 깨진다
  COUNT(*) AS new_users,
  -- 코호트 안의 가장 늦은 Day0 기준으로 관찰이 끝났을 때만 값을 낸다
  IF(MAX(day0) <= DATE_SUB(ANY_VALUE(end_date), INTERVAL 1 DAY),  ROUND(100 * COUNTIF(d1) / COUNT(*), 1), NULL) AS d1_pct,
  IF(MAX(day0) <= DATE_SUB(ANY_VALUE(end_date), INTERVAL 7 DAY),  ROUND(100 * COUNTIF(w1) / COUNT(*), 1), NULL) AS w1_pct,
  IF(MAX(day0) <= DATE_SUB(ANY_VALUE(end_date), INTERVAL 14 DAY), ROUND(100 * COUNTIF(w2) / COUNT(*), 1), NULL) AS w2_pct,
  IF(MAX(day0) <= DATE_SUB(ANY_VALUE(end_date), INTERVAL 7 DAY),  ROUND(100 * COUNTIF(d7) / COUNT(*), 1), NULL) AS d7_pct
FROM users
CROSS JOIN params
GROUP BY GROUPING SETS ((cohort_week, platform), (cohort_week))
ORDER BY cohort_week, platform_label;
