FROM public.ecr.aws/docker/library/alpine:3.22

RUN apk add --no-cache aws-cli helm ca-certificates \
 && aws --version \
 && helm version --short
