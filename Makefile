IMAGE_NAME ?= atlassianlabs/localstack
IMAGE_TAG ?= $(shell cat setup.py | grep version= | sed "s/.*version=['\"]\(.*\)['\"].*/\1/")
VENV_DIR ?= .venv
VENV_RUN = . $(VENV_DIR)/bin/activate
AWS_STS_URL = http://central.maven.org/maven2/com/amazonaws/aws-java-sdk-sts/1.11.14/aws-java-sdk-sts-1.11.14.jar
AWS_STS_TMPFILE = /tmp/aws-java-sdk-sts.jar
TMP_DIR = /tmp/localstack
DATA_DIR ?= $(TMP_DIR)/data
DOCKER_SOCK ?= /var/run/docker.sock

usage:             ## Show this help
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##//'

install:           ## Install npm/pip dependencies, compile code
	make setup-venv && \
		make install-libs && \
		make compile

setup-venv:        # Setup virtualenv
	(test `which virtualenv` || pip install --user virtualenv || sudo pip install virtualenv)
	(test -e $(VENV_DIR) || virtualenv $(VENV_DIR))
	($(VENV_RUN) && pip install --upgrade pip)
	(test ! -e requirements.txt || ($(VENV_RUN) && pip install -r requirements.txt))

install-libs:      ## Install npm/pip dependencies
	(test -e localstack/infra/amazon-kinesis-client/aws-java-sdk-sts.jar || \
			{ (test -e $(AWS_STS_TMPFILE) || curl -o $(AWS_STS_TMPFILE) $(AWS_STS_URL)); \
				mkdir -p localstack/infra/amazon-kinesis-client; \
				cp $(AWS_STS_TMPFILE) localstack/infra/amazon-kinesis-client/aws-java-sdk-sts.jar; }) && \
		(npm install --silent -g npm || sudo npm install --silent -g npm)

install-web:       ## Install npm dependencies for dashboard Web UI
	(cd localstack/dashboard/web && (test ! -e package.json || npm install --silent))

compile:           ## Compile Java code (KCL library utils)
	echo "Compiling"
	javac -cp $(shell $(VENV_RUN); python -c 'from localstack.utils.kinesis import kclipy_helper; print(kclipy_helper.get_kcl_classpath())') localstack/utils/kinesis/java/com/atlassian/*.java
	(test ! -e ext/java || (cd ext/java && mvn -DskipTests package))
	# TODO enable once we want to support Java-based Lambdas
	# (cd localstack/mock && mvn package)

publish:           ## Publish the library to the central PyPi repository
	# build and upload archive
	($(VENV_RUN) && ./setup.py sdist upload)

coveralls:         ## Publish coveralls metrics
	($(VENV_RUN); coveralls)

init:              ## Initialize the infrastructure, make sure all libs are downloaded
	$(VENV_RUN); exec localstack/mock/install.py run

infra:             ## Manually start the local infrastructure for testing
	$(VENV_RUN); exec localstack/mock/infra.py

docker-build:      ## Build Docker image
	docker build -t $(IMAGE_NAME) .
	docker tag $(IMAGE_NAME) $(IMAGE_NAME):$(IMAGE_TAG)

docker-push:       ## Push Docker image to registry
	docker push $(IMAGE_NAME):$(IMAGE_TAG)

docker-push-master:## Push Docker image to registry IF we are currently on the master branch
	(test `git rev-parse --abbrev-ref HEAD` != 'master' && echo "Not on master branch.") || \
		(which pip || (wget https://bootstrap.pypa.io/get-pip.py && python get-pip.py); \
		which docker-squash || pip install docker-squash; \
		docker info | grep Username || docker login -u $$DOCKER_USERNAME -p $$DOCKER_PASSWORD; \
		docker-squash -t $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):$(IMAGE_TAG) && docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest; \
		docker push $(IMAGE_NAME):$(IMAGE_TAG) && docker push $(IMAGE_NAME):latest)

docker-run:        ## Run Docker image locally
	port_mappings="$(shell echo $(SERVICES) | sed 's/[^0-9]/ /g' | sed 's/\([0-9][0-9]*\)/-p \1:\1/g' | sed 's/  */ /g')"; \
		mkdir -p $(TMP_DIR); chmod -R 777 $(TMP_DIR); \
		docker run -it $(ENTRYPOINT) -e DEBUG=$(DEBUG) -e SERVICES=$(SERVICES) -e DATA_DIR=$(DATA_DIR) -e LAMBDA_EXECUTOR=$(LAMBDA_EXECUTOR) -e KINESIS_ERROR_PROBABILITY=$(KINESIS_ERROR_PROBABILITY) -p 4567-4581:4567-4581 -p 8080:8080 $$port_mappings -v $(TMP_DIR):$(TMP_DIR) -v $(DOCKER_SOCK):$(DOCKER_SOCK) -e DOCKER_HOST="unix://$(DOCKER_SOCK)" $(IMAGE_NAME) $(CMD)

web:               ## Start web application (dashboard)
	($(VENV_RUN); bin/localstack web --port=8080)

test:              ## Run automated tests
	make lint && \
		$(VENV_RUN); DEBUG=$(DEBUG) PYTHONPATH=`pwd` nosetests --with-coverage --logging-level=WARNING --nocapture --no-skip --exe --cover-erase --cover-tests --cover-inclusive --cover-package=localstack --with-xunit --exclude='$(VENV_DIR).*' .

test-docker:       ## Run automated tests in Docker
	ENTRYPOINT="--entrypoint= -v `pwd`/localstack/utils:/opt/code/localstack/localstack/utils -v `pwd`/localstack/mock:/opt/code/localstack/localstack/mock" CMD="make test" make docker-run

lint:              ## Run code linter to check code style
	($(VENV_RUN); pep8 --max-line-length=120 --ignore=E128 --exclude=node_modules,legacy,$(VENV_DIR),dist .)

clean:             ## Clean up (npm dependencies, downloaded infrastructure code, compiled Java classes)
	rm -rf localstack/dashboard/web/node_modules/
	rm -rf localstack/mock/target/
	rm -rf localstack/infra/amazon-kinesis-client
	rm -rf localstack/infra/elasticsearch
	rm -rf localstack/node_modules/
	rm -rf $(VENV_DIR)
	rm -f localstack/utils/kinesis/java/com/atlassian/*.class
	rm -f $(AWS_STS_TMPFILE)
	rm -f /tmp/localstack.es.zip

.PHONY: usage compile clean install web install-web infra test install-libs
