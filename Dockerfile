FROM alpine:latest

# Install Unbound and Redis support
RUN apk add --no-cache unbound drill && \
    mkdir -p /etc/unbound/conf.d /var/lib/unbound && \
    chown unbound:unbound /var/lib/unbound

# Copy the system's DNSSEC root key to where our config expects it
RUN cp /usr/share/dnssec-root/trusted-key.key /var/lib/unbound/root.key && \
    chown unbound:unbound /var/lib/unbound/root.key

# Copy configuration files
COPY unbound/conf.d/ /etc/unbound/conf.d/

# Create main config that includes our conf.d files
RUN echo "include: \"/etc/unbound/conf.d/*.conf\"" > /etc/unbound/unbound.conf && \
    chown -R unbound:unbound /etc/unbound

USER unbound
EXPOSE 53/tcp 53/udp
CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
