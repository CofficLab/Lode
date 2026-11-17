# SSH jump host for tunnel integration tests. Password auth (testuser/testpass),
# TCP forwarding enabled so the tunnel can reach the database engines. Test-only
# credentials; never used outside the disposable integration environment.
FROM alpine:3.20

# APK_MIRROR lets restricted networks point apk at a reachable mirror (e.g.
# https://mirrors.aliyun.com). The default is the official Alpine CDN.
ARG APK_MIRROR=https://dl-cdn.alpinelinux.org
# sshd uses the FIRST active occurrence of each directive, so appending overrides
# loses to Alpine's active defaults (e.g. `AllowTcpForwarding no`). Edit in place
# instead; `#*` matches both the commented and active forms of each directive.
RUN sed -i "s|https://dl-cdn.alpinelinux.org|${APK_MIRROR}|g" /etc/apk/repositories \
    && apk add --no-cache openssh \
    && adduser -D -s /bin/sh testuser \
    && echo 'testuser:testpass' | chpasswd \
    && ssh-keygen -A \
    && sed -i \
        -e 's/^#*AllowTcpForwarding.*/AllowTcpForwarding yes/' \
        -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
        -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
        /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]