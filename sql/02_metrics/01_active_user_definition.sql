-- 활성 유저를 "그날 이벤트가 하나라도 있는 유저"로 세면 얼마나 부풀려지는지 확인한다. (포트폴리오 1-2)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-10-26 ~ 2026-11-01, 단위는 유저-일
--
-- 실사용 = 그날 user_engagement 또는 session_start가 있음. 둘 다 앱이 화면에 떠 있을 때만 찍힌다.
-- app_remove나 알림 수신 같은 이벤트를 하나씩 빼는 방식도 생각했지만
-- 앱을 열지 않아도 찍히는 이벤트는 앞으로 또 생길 수 있어서 허용 목록 방식으로 했다.
-- not_engaged 행은 실사용이 아닌 날에 어떤 이벤트가 찍혔는지 보여 준다.
-- iOS는 앱 삭제와 알림 수신 이벤트가 오지 않아 차이가 거의 없다.
-- 뒤의 리텐션, WAU 쿼리는 전부 이 기준을 쓴다.

WITH ud AS (
  -- 유저-일마다: 실사용 이벤트가 있었나 + 그날 찍힌 이벤트 이름 목록
  SELECT
    event_date,
    platform,
    user_pseudo_id,
    LOGICAL_OR(event_name IN ('user_engagement', 'session_start')) AS engaged,
    STRING_AGG(DISTINCT event_name ORDER BY event_name) AS events_that_day
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20261026' AND '20261101'
    AND platform IN ('IOS', 'ANDROID')
  GROUP BY event_date, platform, user_pseudo_id
)
-- ① 플랫폼별: 유저-일 전체(옛 기준) vs 실사용 유저-일(새 기준). 7로 나누면 하루 평균 DAU
SELECT
  'summary' AS part,
  platform,
  CAST(NULL AS STRING) AS events_that_day,
  COUNT(*) AS user_days_any_event,
  COUNTIF(engaged) AS user_days_engaged,
  ROUND(COUNTIF(engaged) / COUNT(*), 3) AS engaged_share
FROM ud
GROUP BY platform

UNION ALL

-- ② 실사용이 아닌 유저-일에 찍힌 이벤트 조합 (플랫폼별 상위 8개)
SELECT
  'not_engaged' AS part,
  platform,
  events_that_day,
  COUNT(*) AS user_days_any_event,
  NULL AS user_days_engaged,
  NULL AS engaged_share
FROM ud
WHERE NOT engaged
GROUP BY platform, events_that_day
QUALIFY ROW_NUMBER() OVER (PARTITION BY platform ORDER BY COUNT(*) DESC) <= 8
ORDER BY part DESC, platform, user_days_any_event DESC;
