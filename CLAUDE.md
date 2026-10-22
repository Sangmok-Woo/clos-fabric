# clos-fabric 작업 규칙

## 실험 폴더

- `experiments/_wip/`: 진행 중인 실험. 새 실험은 `cp -r experiments/_template experiments/_wip/NN-이름`
- `experiments/_completed/`: 정리가 끝난 실험
- `experiments/_archive/`: 끝났고 지금은 쓰지 않는 실험
- 실험 스크립트는 `. "$(dirname "$0")/../../_tools/lab.sh"`로 공통 도구를 불러온다

## packets/

가볍게 캡처해서 구경만 하는 곳. 규칙은 `packets/CLAUDE.md`. 위 README 세 곳 규칙은 적용하지 않는다.

## 실험을 바꾸면 README 세 곳을 같이 고친다

실험을 추가·수정·이동·이름 변경·삭제할 때는 그 실험의 README만 고치고 끝내지 않는다. 같은 작업 안에서 아래를 함께 맞춘다.

1. 실험 자신의 `README.md` (제목, 결론, 실행 방법)
2. `experiments/README.md`의 완료/진행 중 표 (제목, 링크, 주입하는 장애, 상태)
3. 루트 `README.md`의 실험 목록, 결과 표, 진행 중 줄 (제목, 링크, 본 것)
4. `_wip/`에 있는 실험이면 `experiments/_wip/README.md` 표도

제목은 세 곳 모두 같은 문구로 쓴다. 폴더를 옮겼으면 다른 문서에서 그 폴더를 가리키는 링크도 고친다.
끝나면 `CHANGELOG.md`에 항목을 남긴다.
