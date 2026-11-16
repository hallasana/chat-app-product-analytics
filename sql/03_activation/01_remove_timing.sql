-- 설치한 기기가 설치 후 얼마 만에 앱을 지우는지 본다. (포트폴리오 1-3)
-- 입력: your_project.analytics_000000.events_*
-- 기간: 2026-08-25 ~ 2026-10-11, 코호트는 first_open이 8/28 이후인 Android 기기
--
-- Android만 본다. iOS는 app_remove가 수집되지 않는다.
-- 8/28부터인 이유: export 첫 3일은 first_open이 빠져 있어 설치 시각을 알 수 없다.
-- 경과 시간 구간은 앞쪽을 촘촘하게 잡았다(1, 2, 5, 10분 ...). 삭제가 첫 몇 분에 몰려 있어서다.
-- 분모는 두 가지다.
--   cohort_7d: 설치 후 7일을 끝까지 볼 수 있는 기기. 최근에 설치한 기기는 아직 지울 시간이 없어서 뺀다.
--   removed_all: 삭제한 기기 전체. "삭제한 기기 중 몇 %가 10분 안에 지웠나"를 볼 때 쓴다.
-- check 행은 first_open보다 먼저 찍힌 삭제 같은 이상값을 센다.
--
-- 실제 분석은 기기 단위 요약 테이블을 먼저 만들어 놓고 돌렸고 테스트 기기는 직접 확인한 ID 목록으로 뺐다.
-- 여기서는 events_*에서 바로 계산하고 테스트 기기는 "Play 스토어 밖에서 설치된 기기"라는 규칙으로 대신했다.
-- 그래서 포트폴리오 숫자와 조금 다를 수 있다.

WITH params AS (
  SELECT DATE '2026-10-11' AS end_date,        -- 스냅샷 끝 날짜
         DATE '2026-08-28' AS cohort_start      -- first_open이 안정적으로 들어온 첫날
),
test_devices AS (
  -- 규칙 예시: 스토어 외 경로로 설치된 Android 기기 (원본은 수동 확인 목록을 썼다)
  SELECT DISTINCT user_pseudo_id
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260825' AND '20261011'
    AND platform = 'ANDROID'
    AND app_info.install_source IS NOT NULL
    AND app_info.install_source != 'com.android.vending'
    AND user_pseudo_id IS NOT NULL   -- NULL이 섞이면 아래 NOT IN이 전부 걸러 버린다
),
device AS (
  -- 기기 1행: 설치 시각, 삭제 시각, 마지막 활성일
  SELECT
    user_pseudo_id,
    MIN(IF(event_name = 'first_open', TIMESTAMP_MICROS(event_timestamp), NULL)) AS first_open_ts,
    MIN(IF(event_name = 'first_open', PARSE_DATE('%Y%m%d', event_date), NULL)) AS first_open_date,
    MIN(IF(event_name = 'app_remove', TIMESTAMP_MICROS(event_timestamp), NULL)) AS app_remove_ts,
    MIN(IF(event_name = 'app_remove', PARSE_DATE('%Y%m%d', event_date), NULL)) AS remove_date,
    MAX(IF(event_name IN ('user_engagement', 'session_start'), PARSE_DATE('%Y%m%d', event_date), NULL)) AS last_active_date
  FROM `your_project.analytics_000000.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260825' AND '20261011'
    AND platform = 'ANDROID'
    AND event_name IN ('first_open', 'app_remove', 'user_engagement', 'session_start')
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM test_devices)
  GROUP BY user_pseudo_id
),
cohort AS (
  SELECT
    first_open_date,
    DATE_TRUNC(first_open_date, WEEK(MONDAY)) AS cohort_week,
    app_remove_ts IS NOT NULL AS removed,
    DATE_DIFF(remove_date, first_open_date, DAY) AS remove_day,
    TIMESTAMP_DIFF(app_remove_ts, first_open_ts, SECOND) / 60 AS remove_min,
    last_active_date,
    remove_date,
    first_open_date <= DATE_SUB(p.end_date, INTERVAL 7 DAY) AS obs_7d,
    p.end_date
  FROM device
  CROSS JOIN params p
  WHERE first_open_date >= p.cohort_start
),
binned AS (
  SELECT
    *,
    CASE
      WHEN remove_min < 0 THEN -1
      WHEN remove_min <= 1 THEN 1
      WHEN remove_min <= 2 THEN 2
      WHEN remove_min <= 5 THEN 5
      WHEN remove_min <= 10 THEN 10
      WHEN remove_min <= 20 THEN 20
      WHEN remove_min <= 30 THEN 30
      WHEN remove_min <= 60 THEN 60
      WHEN remove_min <= 120 THEN 120
      WHEN remove_min <= 360 THEN 360
      WHEN remove_min <= 720 THEN 720
      WHEN remove_min <= 1440 THEN 1440
      WHEN remove_min <= 2880 THEN 2880
      WHEN remove_min <= 4320 THEN 4320
      WHEN remove_min <= 10080 THEN 10080
      ELSE 99999
    END AS bin_upper_min
  FROM cohort
),
n_list AS (
  SELECT n FROM UNNEST([0, 1, 7]) AS n
)
-- 출력 (긴 형식): section, grp, k, n, d
--   elapsed: 경과 시간 구간별 삭제 기기 수. k = 구간 상한(분), d = 분모 (removed_all = 삭제 기기 전체 / cohort_7d = 7일 관찰 가능 코호트)
--   fixed:   주간 코호트별 Dn 삭제 기기 수 / n일 관찰 가능 코호트 크기. k = n
--   check:   이상값 점검
SELECT 'elapsed' AS section, 'removed_all' AS grp, bin_upper_min AS k, COUNT(*) AS n,
  (SELECT COUNTIF(removed) FROM cohort) AS d
FROM binned
WHERE removed
GROUP BY bin_upper_min

UNION ALL

SELECT 'elapsed', 'cohort_7d', bin_upper_min, COUNT(*),
  (SELECT COUNTIF(obs_7d) FROM cohort)
FROM binned
WHERE removed AND obs_7d
GROUP BY bin_upper_min

UNION ALL

SELECT 'fixed', CAST(cohort_week AS STRING), n_list.n,
  COUNTIF(removed AND remove_day <= n_list.n), COUNT(*)
FROM cohort
CROSS JOIN n_list
WHERE first_open_date <= DATE_SUB(end_date, INTERVAL n_list.n DAY)
GROUP BY cohort_week, n_list.n

UNION ALL

SELECT 'fixed', 'ALL', n_list.n,
  COUNTIF(removed AND remove_day <= n_list.n), COUNT(*)
FROM cohort
CROSS JOIN n_list
WHERE first_open_date <= DATE_SUB(end_date, INTERVAL n_list.n DAY)
GROUP BY n_list.n

UNION ALL

SELECT 'check', x.grp, NULL, SUM(IFNULL(x.n, 0)), COUNT(*)
FROM cohort, UNNEST([
  STRUCT('removed' AS grp, CAST(removed AS INT64) AS n),
  STRUCT('remove_before_first_open', CAST(remove_min < 0 AS INT64)),
  STRUCT('active_after_remove_date', CAST(last_active_date > remove_date AS INT64)),
  STRUCT('obs_7d', CAST(obs_7d AS INT64))
]) AS x
GROUP BY x.grp

ORDER BY section, grp, k;
