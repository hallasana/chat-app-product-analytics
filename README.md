# chat-app-product-analytics

모바일 앱(iOS · Android)의 GA4 → BigQuery 이벤트 export를 BigQuery Standard SQL로 분석한 쿼리 모음입니다.
설계 문서와 실제 수신 이벤트를 대조해 결제 이중 기록을 바로잡고, 활성·리텐션 기준을 정의한 뒤, 설치 후 이탈 시점과 첫 시간 행동, 국가별 신규 코호트 가치를 분석했습니다.
실제 분석에 쓴 비공개 저장소에서 공개할 수 있는 쿼리만 골라 다시 정리한 것입니다. 서비스명은 밝히지 않고 프로젝트 ID와 서비스 고유의 이벤트 이름은 바꿨습니다. 분석 기간은 2026년 8월 ~ 11월입니다.

## 쿼리 목록

| 파일 | 답하는 질문 | 포트폴리오 절 |
| --- | --- | --- |
| `sql/01_data_quality/01_event_inventory_vs_spec.sql` | 설계 문서의 이벤트·파라미터가 실제로 들어오는가? 문서에 없는 것, 한 플랫폼에서만 찍히는 것, 타입이 다른 것은? | 1-1 |
| `sql/01_data_quality/02_purchase_dedup.sql` | 두 종류의 결제 이벤트가 같은 결제를 두 번 세는가? (같은 유저 · 같은 상품 · 10분 이내 매칭, 거래 ID 중복) | 1-1 |
| `sql/02_metrics/01_active_user_definition.sql` | 앱 삭제·알림 수신만 있는 날을 활성에서 빼면 얼마나 달라지는가? | 1-2 |
| `sql/02_metrics/02_retention_d1_w1.sql` | 주별 신규 코호트의 D1, W1(1~7일째 재방문)은 얼마인가? | 1-2 |
| `sql/02_metrics/03_weekly_active_flow.sql` | 주간 활성 유저의 증감을 신규·유지·복귀·이탈로 나누면? | 1-2 |
| `sql/03_activation/01_remove_timing.sql` | 설치한 기기는 설치 후 언제 앱을 지우는가? | 1-3 |
| `sql/03_activation/02_first_hour_behavior_return.sql` | 설치 후 첫 60분에 무엇을 한 기기가 7일 안에 다시 오는가? | 1-3 |
| `sql/04_ads/01_cohort_first_week_value_by_country.sql` | 국가·플랫폼·유입별 신규 코호트의 첫 7일 결제와 활동일은? (광고 회수율 계산 재료) | 1-4 |

각 파일 맨 위 주석에 무엇을 보려는 쿼리인지, 기간, 기준을 그렇게 잡은 이유를 적었습니다.

## 읽을 때 참고

- 데이터는 공개하지 않으므로 그대로 실행되지는 않습니다. 어떤 기준으로 무엇을 계산했는지 읽기 위한 저장소입니다.
- 한 파일에 쿼리가 두 개 들어 있는 경우 `;`로 구분했습니다.
- GA4 export 스키마 기준입니다. 커스텀 이벤트의 숫자 파라미터는 `double_value`, Firebase 자동 수집 이벤트의 숫자는 `int_value`로 들어옵니다.
- 서비스 고유의 이벤트 이름은 일반적인 이름으로 바꿨습니다(`scenario_start`, `scenario_complete`). Firebase 자동 수집 이벤트(`first_open`, `session_start`, `user_engagement`, `app_remove`, `purchase`, `in_app_purchase`)는 원래 이름입니다.
- 활성 사용자, 리텐션, 결제 이벤트의 정의는 `02_metrics/01`, `02_metrics/02`, `01_data_quality/02` 머리말에 있고 뒤의 쿼리들은 그 정의를 그대로 씁니다.
- 테스트 기기 제외는 실제 분석에서 수동 확인한 ID 목록을 썼습니다. 공개판(`03_activation/*`)은 "스토어 외 경로 설치"라는 규칙으로 대체했으므로 결과 숫자가 조금 다를 수 있습니다.

## 결과 수치

쿼리 결과와 해석, 표와 차트는 포트폴리오 문서(지원서에 첨부)에 있습니다.

이 저장소에는 쿼리 결과, CSV, 사용자 ID, 인증 정보, 실제 프로젝트 ID를 넣지 않습니다.
