# 3scale Backend image using the Red Hat 8 Universal Base Image (UBI) for
# minimal space release.
#
# Everything is set up in a single RUN command.
#
# This is based on and tracking the behavior of the more generic Dockerfile.
#
# Knobs you should know about:
#
# - RUBY_VERSION: Ruby version used.
# - BUILD_DEP_PKGS: Packages needed to build/install the project.
# - PUMA_WORKERS: (edit ENV) Default number of Puma workers to serve the app.
#
FROM registry.access.redhat.com/ubi8/ubi-minimal:8.10-1086

LABEL summary="3scale API Management platform backend." \
      description="3scale is an API Management Platform suitable to manage both internal and external API services. This image contains the platform's backend, which takes care of applying rate limits, authorization, and reporting of HTTP(s) requests." \
      io.k8s.description="3scale is an API Management Platform suitable to manage both internal and external API services. This image contains the platform's backend, which takes care of applying rate limits, authorization, and reporting of HTTP(s) requests." \
      io.k8s.display-name="3scale API manager (backend)" \
      io.openshift.expose-services="3000:backend" \
      io.openshift.tags="api, backend, 3scale, 3scale-amp"

# Labels consumed by Red Hat build service
LABEL com.redhat.component="3scale-amp-backend-container" \
      maintainer="eastizle@redhat.com" \
      name="3scale-amp2/backend-rhel8" \
      version="1.18.0" \
      upstream_repo="${CI_APISONATOR_UPSTREAM_URL}" \
      upstream_ref="${CI_APISONATOR_UPSTREAM_COMMIT}"

ARG RUBY_VERSION="3.3"
ARG BUILD_DEPS="tar make file findutils git patch gcc automake autoconf libtool redhat-rpm-config openssl-devel ruby-devel"
ARG PUMA_WORKERS=1

# Set TZ to avoid glibc wasting time with unneeded syscalls
ENV TZ=:/etc/localtime \
    HOME=/home \
    # App-specific env
    RACK_ENV=production \
    CONFIG_SAAS=false \
    CONFIG_LOG_PATH=/tmp/ \
    CONFIG_WORKERS_LOG_FILE=/dev/stdout \
    PUMA_WORKERS=${PUMA_WORKERS} \
    GEMS_REPO=https://repository.jboss.org/nexus/content/groups/rubygems_store/

COPY apisonator ${HOME}/app
RUN mkdir -p /opt/ruby

WORKDIR "${HOME}/app"



# Install Ruby and bundler
RUN echo -e "[ruby]\nname=ruby\nstream=${RUBY_VERSION}\nprofiles=\nstate=enabled\n" > /etc/dnf/modules.d/ruby.module \
 && microdnf update --nodocs \
 && microdnf install --nodocs ruby \
 && chown -R 1001:1001 "${HOME}" \
 && microdnf install --nodocs ${BUILD_DEPS} \
 && microdnf remove rubygem-bundler \
 && mkdir -p "${HOME}/.gem/bin" \
 && echo "gem: --bindir ~/.gem/bin" > "${HOME}/.gemrc" \
 && BUNDLED_WITH=$(cat Gemfile.lock | \
      grep -A 1 "^BUNDLED WITH$" | tail -n 1 | sed -e 's/\s//g') \
# && . /tmp/cachi2.env \
 && gem install -N bundler --version "${BUNDLED_WITH}" -n /usr/local/bin
# && gem sources --add $GEMS_REPO --remove https://rubygems.org/ \
# && gem install -N bundler --version "${BUNDLED_WITH}" --source $GEMS_REPO -n /usr/local/bin

RUN echo Using $(bundle --version) \
# && . /tmp/cachi2.env \
 && bundle config list \
 && bundle config --local silence_root_warning 1 \
 && bundle config --local disable_shared_gems 1 \
 && bundle config --local without development:test \
 && bundle config --local gemfile Gemfile \
 && cp -n openshift/3scale_backend.conf /etc/ \
 && chmod 644 /etc/3scale_backend.conf

# Install Ruby dependencies
RUN BACKEND_VERSION=$(gem build apisonator.gemspec | \
      sed -n -e 's/^\s*Version\:\s*\([^[:space:]]*\)$/\1/p') \
 && gem unpack "apisonator-${BACKEND_VERSION}.gem" --target=/opt/ruby \
 && cd "/opt/ruby/apisonator-${BACKEND_VERSION}" \
# && . /tmp/cachi2.env \
 && bundle install --jobs $(grep -c processor /proc/cpuinfo) \
 && ln -s /opt/ruby/apisonator-${BACKEND_VERSION} /opt/app
# && cp --archive ${HOME}/app/.bundle ${HOME}/app/rubygems-proxy-ca.pem "/opt/ruby/apisonator-${BACKEND_VERSION}/" \
# && mv ${REMOTE_SOURCES_DIR}/apisonator/deps /opt/ruby/deps \
# && SSL_CERT_FILE=/opt/ruby/apisonator-${BACKEND_VERSION}/rubygems-proxy-ca.pem bundle install --jobs $(grep -c processor /proc/cpuinfo) \

# Bundler doesn't install native extensions for gems that are used as local git overrides (which is how cachito provides `git` dependencies in a Gemfile),
# so we need to build those manually, for all such gems that require native extensions (in our case, puma)
# DON'T remove the first `cd` : we need to be inside application folder, so that relative-path resolution of `bundle show` output will work
RUN cd /opt/app \
    && cd $(bundle show puma 2>/dev/null) \
    && ruby ext/puma_http11/extconf.rb \
    && make \
    && mv puma_http11.so lib/puma

# Setup app files
RUN cp ${HOME}/app/openshift/config/puma.rb /opt/app/config/ \
 && cp -n ${HOME}/app/openshift/backend-cron /usr/local/sbin/backend-cron \
 && cp -n ${HOME}/app/openshift/entrypoint.sh /opt/app/ \
 && rm -rf ${HOME}/app \
 && mkdir -p -m 0770 /var/run/3scale/ \
 && mkdir -p -m 0770 /var/log/backend/ \
 && touch /var/log/backend/3scale_backend{,_worker}.log \
 && chmod g+rw /var/log/backend/3scale_backend{,_worker}.log

RUN chmod +t /tmp

RUN mkdir -p /root/licenses/3scale-amp-backend-container && find /opt/ruby -name licenses.xml -exec cp '{}' /root/licenses/3scale-amp-backend-container/ \;

# Bundler runs git commands on git dependencies when configured as local git repos
# https://bundler.io/guides/git.html#local-git-repos
# Some backend deps are provided with git overrides (like puma)
# git will check if the current user is the owner of the git repository folder
# The git check was added in https://github.com/git/git/commit/8959555cee7ec045958f9b6dd62e541affb7e7d9 and included in git v2.35.2 or newer.
# Openshift will change the effective userID, so this git check needs to be bypassed until better solution is found.
RUN git config --global --add safe.directory '*'

# Ensure safe defaults within the container for general case as well as to cover OpenShift specific case where the unprivileged user who runs the container is member of the root Linux group
RUN chown -R 1001:0 /opt/ruby \
    && chmod -R 750 /opt/ruby

EXPOSE 3000

USER 1001

WORKDIR /opt/app

ENTRYPOINT ["/bin/bash", "--", "/opt/app/entrypoint.sh"]
