FROM ruby:2.7

ENV RAILS_ENV='development'
ENV RAKE_ENV='development'
ENV NODE_ENV='development'
RUN apt update && apt install -y libcurl3-dev libpq-dev zlib1g-dev libssl-dev libreadline-dev zlib1g-dev 
# Add node for webpack 
RUN curl -sL https://deb.nodesource.com/setup_12.x | bash -
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list
RUN apt-get update; apt-get install -y yarn

RUN mkdir /opt/ds
WORKDIR /opt/ds

# Adding gems
COPY Gemfile* ./
RUN bundle install --jobs 20 --retry 5 --without development test
COPY . ./
RUN npm install
RUN npm run webpack:build

EXPOSE $PORT
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
