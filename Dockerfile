FROM --platform=linux/amd64 ubuntu:20.04 as builder

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential

ADD . /dev86
WORKDIR /dev86
RUN make

RUN mkdir -p /deps
RUN ldd /dev86/bin/ld86 | tr -s '[:blank:]' '\n' | grep '^/' | xargs -I % sh -c 'cp % /deps;'

FROM ubuntu:20.04 as package

COPY --from=builder /deps /deps
COPY --from=builder /dev86/bin/ld86 /dev86/bin/ld86
ENV LD_LIBRARY_PATH=/deps
