<div align="center">

<img src=".github/assets/banner.png" alt="PSM" width="820">

# PSM · Proxy Stack Manager

**명령 한 줄로 VPS 에 나만의 프록시 서버: VLESS REALITY, Hysteria2, TUIC, AnyTLS**<br>
Xray / sing-box / mihomo · 443 포트 공유 · 사용자 계정 · 트래픽 한도 · 서버 이전

<p>
  <a href="https://psm-docs.pages.dev/en/"><b>📖 문서 (English)</b></a> ·
  <a href="README_EN.md">English</a> ·
  <a href="README.md">简体中文</a>
</p>

</div>

## 설치

VPS 에서 root 로 실행:

```bash
bash <(curl -fsSL https://psm.jinqians.com)
```

설치 후 `psm` 을 실행하면 관리 메뉴가 열립니다. 인터페이스는 한국어를 지원합니다(메뉴의 "Language").

## 주요 기능

- VLESS REALITY / Vision / XHTTP, Hysteria2(포트 호핑), TUIC v5, AnyTLS, Snell, Shadowsocks 2022, Trojan, VMess, WireGuard
- Xray, sing-box, mihomo 세 코어를 동시에 사용
- 여러 노드가 443 포트 하나를 공유
- 공유 링크, QR 코드, 구독
- 사용자별 계정, 만료일, 월 트래픽 한도
- `psm migrate push root@새서버` 로 서버 이전
- `psm doctor --fix` 로 진단 및 자동 복구

지원 시스템: Debian, Ubuntu, Alpine, RHEL / Rocky Linux / AlmaLinux (x86_64, arm64).

자세한 사용법은 [영문 문서](https://psm-docs.pages.dev/en/)를 참고하세요.

## 라이선스

[AGPL-3.0](LICENSE). 거주 지역의 법률을 준수해 사용하세요.
