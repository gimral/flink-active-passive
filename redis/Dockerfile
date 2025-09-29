FROM alpine:3.22.1
RUN apk add --no-cache redis
COPY check-redis-key.sh /usr/local/bin/init-check.sh
RUN chmod +x /usr/local/bin/init-check.sh
WORKDIR /usr/local/bin
ENTRYPOINT ["/bin/sh"]