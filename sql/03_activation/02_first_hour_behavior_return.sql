-- 설치 후 첫 60분에 무엇을 한 기기가 7일 안에 다시 오는지 본다. (포트폴리오 1-3)
-- 운영 목표였던 "첫 시나리오 완료"와 "채팅 메시지 1개 이상"을 비교한다.
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-08-25 ~ 2026-10-11, 코호트는 first_open이 9/5 ~ 10/4인 Android 기기
--
-- 9/5부터인 이유: 그날부터 온보딩 뒤 첫 시나리오에 자동으로 들어가게 바뀌었다. 그 전 기기는 첫 세션 구조가 다르다.
-- 채팅은 전송에 성공한 메시지만 센다.
-- 재방문 = 설치 다음 날부터 7일째 사이에 하루라도 활성.
-- 날짜와 자정 판정은 GA4 속성 시간대가 Asia/Seoul이라는 전제로 한다.
-- 아래 기기는 뺐다.
--   60분 안에 앱을 지운 기기: 질문이 "첫 시간을 넘긴 기기 중 누가 돌아오나"라서다. 일찍 지운 기기는 01_remove_timing에서 본다.
--   60분 창이 자정을 넘는 기기: 창 안의 활동이 "다음 날 활성"으로 잡혀 버린다.
--   설치 후 7일이 지나지 않은 기기, 테스트 기기
-- 이렇게 걸렀기 때문에 여기 재방문율은 02_retention_d1_w1의 W1보다 훨씬 높다. 분모가 다르다.
-- 결과는 상관관계다. 원래 열심인 사람이 채팅도 하고 다시 오는 것일 수 있다.
-- 신뢰구간과 회귀는 이 집계를 받아 Python에서 계산했다.
--
-- 실제 분석은 요약 테이블을 만들어 조인했고 테스트 기기는 ID 목록으로 뺐다.
-- 여기서는 events_*에서 바로 계산하고 01_remove_timing과 같은 규칙으로 대신했다. 기기 ID는 출력하지 않는다.

WITH params AS (
  SELECT DATE '2026-10-11' AS end_date,
         DATE '2026-09-05' AS cohort_start
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260825' AND '20261011'
    AND platform = 'ANDROID'
    AND app_info.install_source IS NOT NULL
    AND app_info.install_source != 'com.android.vending'
    AND user_pseudo_id IS NOT NULL   -- NULL이 섞이면 아래 NOT IN이 전부 걸러 버린다
),
device AS (
  -- 기기 1행: 첫 first_open 시각, 첫 app_remove 시각
  SELECT
    user_pseudo_id,
    MIN(IF(event_name = 'first_open', TIMESTAMP_MICROS(event_timestamp), NULL)) AS first_open_ts,
    MIN(IF(event_name = 'first_open', PARSE_DATE('%Y%m%d', event_date), NULL)) AS first_open_date,
    MIN(IF(event_name = 'app_remove', TIMESTAMP_MICROS(event_timestamp), NULL)) AS app_remove_ts
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260825' AND '20261011'
    AND platform = 'ANDROID'
    AND event_name IN ('first_open', 'app_remove')
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM test_devices)
  GROUP BY user_pseudo_id
),
cohort AS (
  -- 코호트와 모집단 플래그
  SELECT
    d.user_pseudo_id,
    d.first_open_ts,
    d.first_open_date,
    d.first_open_date <= DATE_SUB(p.end_date, INTERVAL 7 DAY) AS obs7,
    DATE(TIMESTAMP_ADD(d.first_open_ts, INTERVAL 60 MINUTE), 'Asia/Seoul') > d.first_open_date AS cross_midnight,
    IFNULL(TIMESTAMP_DIFF(d.app_remove_ts, d.first_open_ts, SECOND) <= 3600, FALSE) AS removed_60m
  FROM device d
  CROSS JOIN params p
  WHERE d.first_open_date >= p.cohort_start
),
ev AS (
  -- 60분 창 안의 행동 이벤트
  SELECT
    cohort.user_pseudo_id,
    e.event_name,
    TIMESTAMP_MICROS(e.event_timestamp) AS ts,
    e.event_bundle_sequence_id AS seq,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING))
     FROM UNNEST(e.event_params) WHERE key = 'session_id') AS session_id,
    -- 앱이 보내는 불리언은 double(0.0/1.0)이나 문자열('true')로 들어올 수 있어 문자열로 통일한다
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING), CAST(CAST(value.double_value AS INT64) AS STRING))
     FROM UNNEST(e.event_params) WHERE key = 'is_succeeded') AS is_succeeded
  FROM `your_project.analytics_000000.events_*` e
  JOIN cohort USING (user_pseudo_id)
  WHERE e._TABLE_SUFFIX BETWEEN '20260905' AND '20261011'
    AND e.platform = 'ANDROID'
    AND e.event_name IN ('scenario_start', 'scenario_complete', 'chat_message_send')
    AND TIMESTAMP_MICROS(e.event_timestamp) BETWEEN cohort.first_open_ts AND TIMESTAMP_ADD(cohort.first_open_ts, INTERVAL 60 MINUTE)
),
first_scenario AS (
  -- 창 안 첫 시나리오 (가장 이른 start 하나)
  SELECT
    user_pseudo_id,
    ARRAY_AGG(session_id ORDER BY ts, seq LIMIT 1)[OFFSET(0)] AS session_id
  FROM ev
  WHERE event_name = 'scenario_start'
  GROUP BY user_pseudo_id
),
scenario AS (
  SELECT
    f.user_pseudo_id,
    LOGICAL_OR(e.event_name = 'scenario_complete' AND e.session_id = f.session_id) AS first_scenario_completed_60m
  FROM first_scenario f
  JOIN ev e USING (user_pseudo_id)
  GROUP BY f.user_pseudo_id
),
chat AS (
  SELECT
    user_pseudo_id,
    COUNTIF(event_name = 'chat_message_send' AND LOWER(is_succeeded) IN ('1', 'true')) AS n_chat_ok_60m
  FROM ev
  GROUP BY user_pseudo_id
),
active AS (
  -- 결과: 설치 다음 날 ~ 7일째 사이에 하루라도 활성
  SELECT
    cohort.user_pseudo_id,
    LOGICAL_OR(DATE_DIFF(PARSE_DATE('%Y%m%d', e.event_date), cohort.first_open_date, DAY) BETWEEN 1 AND 7) AS d1_7
  FROM `your_project.analytics_000000.events_*` e
  JOIN cohort USING (user_pseudo_id)
  WHERE e._TABLE_SUFFIX BETWEEN '20260905' AND '20261011'
    AND e.platform = 'ANDROID'
    AND e.event_name IN ('user_engagement', 'session_start')
  GROUP BY cohort.user_pseudo_id
),
population AS (
  -- 분석 대상: 7일 관찰 가능 + 자정 안 넘음 + 60분 안 미삭제
  SELECT
    cohort.user_pseudo_id,
    IFNULL(s.first_scenario_completed_60m, FALSE) AS first_scenario_completed_60m,
    IFNULL(c.n_chat_ok_60m, 0) AS n_chat_ok_60m,
    IFNULL(a.d1_7, FALSE) AS d1_7
  FROM cohort
  LEFT JOIN scenario s USING (user_pseudo_id)
  LEFT JOIN chat c USING (user_pseudo_id)
  LEFT JOIN active a USING (user_pseudo_id)
  WHERE cohort.obs7 AND NOT cohort.cross_midnight AND NOT cohort.removed_60m
)
-- 행동별 D1~7 재방문율. 기기 ID는 출력하지 않는다
-- behavior 앞의 숫자는 정렬용이다. 전체 행이 맨 위에 오게 하려는 것이다.
SELECT behavior, value, COUNT(*) AS devices, COUNTIF(d1_7) AS returned_d1_7,
  ROUND(100 * COUNTIF(d1_7) / COUNT(*), 1) AS return_pct
FROM population,
UNNEST([
  STRUCT('0_population' AS behavior, 'all' AS value),
  STRUCT('1_first_scenario_completed_60m', IF(first_scenario_completed_60m, 'yes', 'no')),
  STRUCT('2_chat_message_ok_60m', IF(n_chat_ok_60m >= 1, 'yes', 'no')),
  STRUCT('3_chat_message_ok_60m_bucket',
    CASE
      WHEN n_chat_ok_60m = 0 THEN '0'
      WHEN n_chat_ok_60m = 1 THEN '1'
      WHEN n_chat_ok_60m BETWEEN 2 AND 4 THEN '2-4'
      WHEN n_chat_ok_60m BETWEEN 5 AND 9 THEN '5-9'
      ELSE '10+'
    END)
])
GROUP BY behavior, value
ORDER BY behavior, value;
