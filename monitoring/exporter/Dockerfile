# docker CLI(호스트 소켓으로 라우터에 docker exec) + python3(수집기)만 있으면 된다.
FROM docker:27-cli
RUN apk add --no-cache python3
COPY collector.py /collector.py
EXPOSE 9600
ENTRYPOINT ["python3", "/collector.py"]
