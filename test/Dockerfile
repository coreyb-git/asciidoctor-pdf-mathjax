FROM asciidoctor/docker-asciidoctor:1.82

RUN apk add --upgrade nodejs npm
RUN npm install -g mathjax-node
ENV NODE_PATH=/usr/local/lib/node_modules

RUN apk add diff-pdf
RUN apk add ruby-minitest

ENTRYPOINT ["bash", "-c", "exec \"$@\"", "--"]

WORKDIR /documents
