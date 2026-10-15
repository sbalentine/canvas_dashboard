FROM ghcr.io/home-assistant/aarch64-base:3.22

RUN apk add --no-cache \
    ruby \
    ruby-webrick && \
    gem install --no-document \
      base64:0.3.0 \
      net-smtp:0.5.2 \
      rubyzip:3.7.0

WORKDIR /app

COPY app.rb /app/app.rb
COPY lib /app/lib
COPY views /app/views
COPY public /app/public
COPY icon.png /app/icon.png

COPY run.sh /run.sh

RUN chmod a+x /run.sh

CMD ["/run.sh"]
