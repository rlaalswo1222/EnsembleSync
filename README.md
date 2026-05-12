<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:F97316,50:FBBF24,100:F97316&height=220&section=header&text=🎵%20EnsembleSync&fontSize=60&fontColor=fff&animation=twinkling&fontAlignY=38&desc=합주%20피드백%20협업%20플랫폼&descAlignY=58&descSize=20&descColor=fff"/>
</div>

<div align="center">
  <a href="https://git.io/typing-svg">
    <img src="https://readme-typing-svg.demolab.com?font=Fira+Code&weight=700&size=20&pause=1000&color=FBBF24&center=true&vCenter=true&random=false&width=600&lines=🎼+실시간+악보+협업;🥁+BPM+%2F+피치+분석;🎸+음원+트랙+분리;🎯+싱크로율+계산" alt="Typing SVG" />
  </a>
</div>

<br/>

<div align="center">

[![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=flat-square&logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Redis](https://img.shields.io/badge/Redis-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io)
[![AWS](https://img.shields.io/badge/AWS-232F3E?style=flat-square&logo=amazonaws&logoColor=white)](https://aws.amazon.com)
[![Celery](https://img.shields.io/badge/Celery-37814A?style=flat-square&logo=celery&logoColor=white)](https://docs.celeryq.dev)
[![WebSocket](https://img.shields.io/badge/WebSocket-000000?style=flat-square&logo=socket.io&logoColor=white)]()

</div>

---

## 🌟 프로젝트 배경

> **"합주의 현실적인 벽에서 시작된 프로젝트"**

합주 팀이 연습 후 피드백을 주고받는 방식은 아직도 구두와 감에 의존합니다.

```
❌  "후반부에서 좀 빨라지는 것 같아" → 정확히 몇 BPM? 몇 번째 마디부터?
❌  "보컬이 음정이 조금 낮은 것 같아" → 어느 구간? 몇 cent?
❌  "3번 마디 두 번째 박자 부분 말이야" → 악보 보면서 동시에 얘기할 수 없음
```

```
✅  EnsembleSync → 데이터 기반 피드백, 실시간 악보 협업
```

---

## 🎯 핵심 기능

<table>
  <tr>
    <td width="50%">
      <h3>🎼 실시간 악보 협업</h3>
      <p>6자리 방 코드로 팀원 전원이 동일한 악보에 실시간 동시 필기합니다. 한 사람의 필기가 모든 참여자 화면에 즉시 반영됩니다.</p>
      <ul>
        <li>펜 / 형광펜 / 화살표 / 텍스트 / 지우개</li>
        <li>색상 5종 및 굵기 조절</li>
        <li>실행취소 및 전체 삭제</li>
        <li>다른 참여자 커서 실시간 표시</li>
      </ul>
    </td>
    <td width="50%">
      <h3>🥁 BPM 시각화</h3>
      <p>librosa로 구간별 BPM을 자동 분석하여 템포가 빨라지거나 느려지는 구간을 그래프로 시각화합니다.</p>
      <ul>
        <li>구간별 BPM 그래프 시각화</li>
        <li>원곡 BPM 기준선 오버레이</li>
        <li>이탈 구간 색상 강조 표시</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <h3>🎯 싱크로율 분석</h3>
      <p>원곡과 녹음 파일을 DTW 알고리즘으로 비교하여 싱크로율을 자동 수치화합니다.</p>
      <ul>
        <li>전체 싱크로율 퍼센트 제공</li>
        <li>구간별 이탈 지점 타임라인 표시</li>
      </ul>
    </td>
    <td width="50%">
      <h3>🎤 보컬 피치 분석</h3>
      <p>pYIN / CREPE 모델로 보컬 피치를 분석하고 음정이 어긋나는 구간을 반음(cent) 단위로 자동 기록합니다.</p>
      <ul>
        <li>보컬 피치 타임라인 자동 기록</li>
        <li>음정 이탈 구간 및 이탈 폭(cent) 표시</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <h3>🎸 세션별 음원 트랙 분리</h3>
      <p>Demucs 모델로 합주 녹음에서 악기별 트랙을 자동 분리합니다. 각 세션 멤버가 자신의 파트만 집중적으로 모니터링할 수 있습니다.</p>
      <ul>
        <li>보컬 / 드럼 / 베이스 / 기타 트랙 분리</li>
        <li>분리된 트랙 개별 재생 및 다운로드</li>
        <li>Celery 비동기 처리로 앱 응답성 유지</li>
      </ul>
    </td>
  </tr>
</table>

---

## 👥 팀원

<div align="center">

| <img src="https://github.com/rlaalswo1222.png" width="80px" height="80px" style="border-radius:50%"/> | <img src="https://github.com/ghost.png" width="80px" height="80px" style="border-radius:50%"/> | <img src="https://github.com/ghost.png" width="80px" height="80px" style="border-radius:50%"/> | <img src="https://github.com/ghost.png" width="80px" height="80px" style="border-radius:50%"/> |
|:---:|:---:|:---:|:---:|
| **김민재** | **임지수** | **최기훈** | **문준호** |
| PM / Flutter UI | Flutter UI | Backend | DB 설계 |
| [@rlaalswo1222](https://github.com/rlaalswo1222) | - | - | - |

</div>

<br/>

<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:F97316,50:FBBF24,100:F97316&height=120&section=footer"/>
</div>
