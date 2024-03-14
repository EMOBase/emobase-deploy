FROM openjdk:jre-alpine

ARG DOWNLOAD=https://h2database.com/h2-2019-03-13.zip
ENV DATA_DIR=/opt/h2-data

RUN apk add --no-cache curl
RUN mkdir -p ${DATA_DIR} \
    && curl --insecure ${DOWNLOAD} -o h2.zip \
    && unzip h2.zip -d /opt/ \
    && rm h2.zip

WORKDIR /opt/h2-data

EXPOSE 8082 9092

CMD java -cp /opt/h2/bin/h2*.jar org.h2.tools.Server -ifNotExists -web -webAllowOthers -tcp -tcpAllowOthers -baseDir ${DATA_DIR}
