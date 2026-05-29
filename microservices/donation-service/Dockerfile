FROM golang:1.21-alpine AS builder

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" -o /out/donation-service .


FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/donation-service /usr/local/bin/donation-service

ENV PORT=8082
EXPOSE 8082

USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/donation-service"]
