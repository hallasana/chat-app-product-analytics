-- 설계 문서에 적힌 이벤트와 파라미터가 실제로 들어오는지 대조하기 위한 목록. (포트폴리오 1-1)
-- 결과를 CSV로 받아 설계 문서 표 옆에 놓고 봤다.
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-10-09 ~ 2026-11-05 (28일)
--
-- 28일로 잡은 이유: 기능마다 이벤트 수집 시작일이 달라서 모든 이벤트가 한 번은 들어올 만한 가장 짧은 기간이다.
-- 플랫폼별로 나눈 이유: 한쪽 플랫폼에서만 찍히는 이벤트가 실제로 있었다.
-- SDK가 자동으로 붙이는 파라미터(ga_session_id, firebase_* 등)는 대조 대상이 아니라 뺐다.
-- 값 예시는 고유값이 20개 이하인 문자열에만 보여 준다. ID나 자유 텍스트가 결과에 찍히지 않게 하려는 것이다.
-- 주의: 앱이 보내는 숫자 파라미터는 double_value로, Firebase 자동 수집 이벤트의 숫자는 int_value로 들어온다.
--       int_value로만 꺼내면 앱이 보낸 값은 전부 NULL이 된다.

-- ① 이벤트 목록: 이벤트 × 플랫폼별 건수, 유저 수, 관측 일수, 첫·마지막 날짜, 앱 버전
SELECT
  event_name,
  platform,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNT(DISTINCT event_date) AS days_seen,
  MIN(event_date) AS first_date,
  MAX(event_date) AS last_date,
  STRING_AGG(DISTINCT app_info.version ORDER BY app_info.version) AS app_versions
FROM `your_project.analytics_000000.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20261009' AND '20261105'
  AND platform IN ('IOS', 'ANDROID')
GROUP BY event_name, platform
ORDER BY event_name, platform;

-- ② 파라미터 목록: 이벤트 × 플랫폼 × 파라미터 키별 채움률, 값 타입, 고유값 수, 값 예시
WITH ev AS (
  SELECT event_name, platform, event_params
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20261009' AND '20261105'
    AND platform IN ('IOS', 'ANDROID')
),
totals AS (
  SELECT event_name, platform, COUNT(*) AS total_events
  FROM ev
  GROUP BY event_name, platform
),
params AS (
  SELECT
    event_name,
    platform,
    p.key,
    COUNT(*) AS n_with_key,
    COUNTIF(p.value.string_value IS NOT NULL) AS n_string,
    COUNTIF(p.value.int_value IS NOT NULL) AS n_int,
    COUNTIF(p.value.double_value IS NOT NULL OR p.value.float_value IS NOT NULL) AS n_double,
    COUNTIF(p.value.string_value = '') AS n_empty_string,
    APPROX_COUNT_DISTINCT(COALESCE(p.value.string_value,
                                   CAST(p.value.int_value AS STRING),
                                   CAST(p.value.double_value AS STRING))) AS n_distinct,
    APPROX_TOP_COUNT(p.value.string_value, 5) AS top_strings
  FROM ev, UNNEST(event_params) AS p
  WHERE p.key NOT IN (
      -- SDK 자동 메타데이터: 설계 문서 대조 대상이 아님
      'ga_session_id', 'ga_session_number', 'engaged_session_event', 'engagement_time_msec',
      'session_engaged', 'entrances', 'ga_dedupe_id', 'validated', 'update_with_analytics',
      'previous_first_open_count', 'system_app', 'system_app_update', 'previous_app_version',
      'previous_os_version', 'campaign_info_source')
    AND NOT STARTS_WITH(p.key, 'firebase_')
  GROUP BY event_name, platform, p.key
)
SELECT
  p.event_name,
  p.platform,
  p.key,
  p.n_with_key,
  t.total_events,
  ROUND(p.n_with_key / t.total_events, 3) AS fill_rate,
  CASE
    WHEN p.n_string > 0 AND p.n_int + p.n_double = 0 THEN 'string'
    WHEN p.n_int > 0 AND p.n_string + p.n_double = 0 THEN 'int'
    WHEN p.n_double > 0 AND p.n_string + p.n_int = 0 THEN 'double'
    WHEN p.n_with_key > 0 AND p.n_string + p.n_int + p.n_double = 0 THEN 'null_only'
    ELSE 'mixed'
  END AS value_type,
  p.n_empty_string,
  p.n_distinct,
  -- 고유값이 적은 문자열(상태값, 유형 코드 등)만 예시를 보여 준다
  IF(p.n_string > 0 AND p.n_distinct <= 20,
     (SELECT STRING_AGG(CONCAT(v.value, ':', CAST(v.count AS STRING)), ' | ') FROM UNNEST(p.top_strings) v),
     NULL) AS top_values
FROM params p
JOIN totals t USING (event_name, platform)
ORDER BY p.event_name, p.platform, p.key;
