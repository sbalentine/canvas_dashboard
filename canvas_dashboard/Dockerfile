FROM ghcr.io/home-assistant/aarch64-base:3.22

RUN apk add --no-cache \
    ruby \
    ruby-webrick

WORKDIR /app

COPY app.rb /app/app.rb
COPY lib /app/lib
COPY views /app/views
COPY public /app/public

COPY run.sh /run.sh

RUN chmod a+x /run.sh

CMD ["/run.sh"]
