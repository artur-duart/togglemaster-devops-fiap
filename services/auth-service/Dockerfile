FROM golang:1.24-alpine AS builder
WORKDIR /app

COPY . .
RUN go mod tidy
RUN go build -o auth-service

FROM alpine:3.24.0

RUN adduser -D appuser
COPY --chown=appuser:appuser --from=builder /app/auth-service .
USER appuser

HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -q -O /dev/null http://localhost:8001/health || exit 1

EXPOSE 8001
CMD ["./auth-service"]
