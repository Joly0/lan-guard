FROM alpine:3.24

RUN apk add --no-cache iptables ip6tables

COPY --chmod=755 lan-guard.sh /usr/local/bin/lan-guard

# start-interval lets depends_on (condition: service_healthy) release the
# dependent containers within a second of the rules landing, instead of
# waiting a full interval.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --start-interval=1s --retries=2 \
    CMD ["lan-guard", "health"]

ENTRYPOINT ["lan-guard"]
CMD ["run"]
