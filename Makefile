# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License;
# you may not use this file except in compliance with the Elastic License.

#################################
##  --      Variables      --  ##
#################################

# reads file '.env', ignores if it doesn't exist
-include .env

# make sure sub-commands don't use eg. fish shell
export SHELL := /bin/bash

KUBECTL_CLUSTER := $(shell kubectl config current-context 2> /dev/null)

REPOSITORY 	?= eck
NAME       	?= eck-operator
VERSION    	?= $(shell cat VERSION)
SNAPSHOT   	?= true

# Default to debug logging
LOG_VERBOSITY ?= 1

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq ($(shell go env GOBIN),)
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# find or download controller-gen
# note this does not validate the version
controller-gen:
ifeq ($(shell command -v controller-gen),)
	@(cd /tmp; GO111MODULE=on go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.1)
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

## -- Docker image

# on GKE, use GCR and GCLOUD_PROJECT
ifneq ($(findstring gke_,$(KUBECTL_CLUSTER)),)
	REGISTRY ?= eu.gcr.io
else
	# default to local registry
	REGISTRY ?= localhost:5000
endif

# suffix image name with current user name
IMG_SUFFIX ?= -$(subst _,,$(USER))
IMG ?= $(REGISTRY)/$(REPOSITORY)/$(NAME)$(IMG_SUFFIX)
TAG ?= $(shell git rev-parse --short --verify HEAD)
OPERATOR_IMAGE ?= $(IMG):$(VERSION)-$(TAG)


GO_LDFLAGS := -X github.com/elastic/cloud-on-k8s/pkg/about.version=$(VERSION) \
	-X github.com/elastic/cloud-on-k8s/pkg/about.buildHash=$(TAG) \
	-X github.com/elastic/cloud-on-k8s/pkg/about.buildDate=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ') \
	-X github.com/elastic/cloud-on-k8s/pkg/about.buildSnapshot=$(SNAPSHOT)

# Setting for CI, if set to true will prevent building and using local Docker image
SKIP_DOCKER_COMMAND ?= false

## -- Namespaces

# namespace in which the global operator is deployed (see config/global-operator)
GLOBAL_OPERATOR_NAMESPACE ?= elastic-system
# namespace in which the namespace operator is deployed (see config/namespace-operator)
NAMESPACE_OPERATOR_NAMESPACE ?= elastic-namespace-operators
# comma separated list of namespaces in which the namespace operator should watch resources
MANAGED_NAMESPACES ?=

## -- Security

# should environments be configured with PSP ?
# TODO: only relevant on GKE for e2e tests for the moment
PSP ?= 0

#####################################
##  --       Development       --  ##
#####################################

all: dependencies lint check-license-header unit integration e2e-compile elastic-operator

## -- build

dependencies:
	go mod tidy -v && go mod download

# Generate code, CRDs and documentation
ALL_CRDS=config/crds/all-crds.yaml
generate: generate-crds generate-api-docs generate-notice-file

go-generate:
	# we use this in pkg/controller/common/license
	go generate -tags='$(GO_TAGS)' ./pkg/... ./cmd/...

generate-crds: go-generate controller-gen
	$(CONTROLLER_GEN) webhook object:headerFile=./hack/boilerplate.go.txt paths=./pkg/apis/...
	# Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) crd paths="./pkg/apis/..." output:crd:artifacts:config=config/crds/bases
	# apply patches to work around some CRD generation issues, and merge them into a single file
	kubectl kustomize config/crds/patches > $(ALL_CRDS)
	# generate an all-in-one version including the operator manifests
	$(MAKE) --no-print-directory generate-all-in-one

generate-api-docs:
	@hack/api-docs/build.sh

generate-notice-file:
	@hack/licence-detector/generate-notice.sh

elastic-operator: generate
	go build -mod=readonly -ldflags "$(GO_LDFLAGS)" -tags='$(GO_TAGS)' -o bin/elastic-operator github.com/elastic/cloud-on-k8s/cmd

clean:
	rm -f pkg/controller/common/license/zz_generated.pubkey.go

## -- tests

unit: clean
	go test ./pkg/... ./cmd/... -cover

unit_xml: clean
	gotestsum --junitfile unit-tests.xml -- -cover ./pkg/... ./cmd/...

integration: GO_TAGS += integration
integration: clean generate-crds
	go test -tags='$(GO_TAGS)' ./pkg/... ./cmd/... -cover

integration_xml: GO_TAGS += integration
integration_xml: clean generate-crds
	gotestsum --junitfile integration-tests.xml -- -tags='$(GO_TAGS)' -cover ./pkg/... ./cmd/...

lint:
	golangci-lint run

#############################
##  --       Run       --  ##
#############################

install-crds: generate-crds
	kubectl apply -f $(ALL_CRDS)

# Run locally against the configured Kubernetes cluster, with port-forwarding enabled so that
# the operator can reach services running in the cluster through k8s port-forward feature
run: install-crds go-run

go-run:
	# Run the operator locally with role All, with debug logs, operator image set to latest and operator namespace for a global operator
	AUTO_PORT_FORWARD=true \
		go run \
			-ldflags "$(GO_LDFLAGS)" \
			-tags "$(GO_TAGS)" \
			./cmd/main.go manager \
				--development --operator-roles=global,namespace \
				--log-verbosity=$(LOG_VERBOSITY) \
				--ca-cert-validity=10h --ca-cert-rotate-before=1h \
				--operator-namespace=default \
				--namespaces=$(MANAGED_NAMESPACES) \
				--manage-webhook-certs=false

go-debug:
	@(cd cmd &&	AUTO_PORT_FORWARD=true dlv debug \
		--build-flags="-ldflags '$(GO_LDFLAGS)'" \
		-- \
		manager \
		--development \
		--operator-roles=global,namespace \
		--log-verbosity=$(LOG_VERBOSITY) \
		--ca-cert-validity=10h \
		--ca-cert-rotate-before=1h \
		--operator-namespace=default \
		--namespaces=$(MANAGED_NAMESPACES) \
		--manage-webhook-certs=false)

build-operator-image:
ifeq ($(SKIP_DOCKER_COMMAND), false)
	$(MAKE) docker-build docker-push
endif

# if the current k8s cluster is on GKE, GCLOUD_PROJECT must be set
check-gke:
ifneq ($(findstring gke_,$(KUBECTL_CLUSTER)),)
ifndef GCLOUD_PROJECT
	$(error GCLOUD_PROJECT not set while GKE detected)
endif
endif

# Deploy both the global and namespace operators against the current k8s cluster
deploy: check-gke install-crds build-operator-image apply-operators

apply-operators:
	OPERATOR_IMAGE=$(OPERATOR_IMAGE) \
	NAMESPACE=$(GLOBAL_OPERATOR_NAMESPACE) \
		$(MAKE) --no-print-directory -sC config/operator generate-global | kubectl apply -f -
	OPERATOR_IMAGE=$(OPERATOR_IMAGE) \
	NAMESPACE=$(NAMESPACE_OPERATOR_NAMESPACE) \
	MANAGED_NAMESPACE=$(MANAGED_NAMESPACE) \
		$(MAKE) --no-print-directory -sC config/operator generate-namespace | kubectl apply -f -

apply-psp:
	kubectl apply -f config/dev/elastic-psp.yaml

ALL_IN_ONE_OUTPUT_FILE=config/all-in-one.yaml

# merge all-in-one crds with operator manifests
generate-all-in-one:
	cp -f $(ALL_CRDS) $(ALL_IN_ONE_OUTPUT_FILE)
	OPERATOR_IMAGE=$(OPERATOR_IMAGE) \
		NAMESPACE=$(GLOBAL_OPERATOR_NAMESPACE) \
		$(MAKE) --no-print-directory -sC config/operator generate-all-in-one >> $(ALL_IN_ONE_OUTPUT_FILE)

# Deploy an all in one operator against the current k8s cluster
deploy-all-in-one: GO_TAGS ?= release
deploy-all-in-one: docker-build docker-push
	kubectl apply -f $(ALL_IN_ONE_OUTPUT_FILE)

logs-namespace-operator:
	@ kubectl --namespace=$(NAMESPACE_OPERATOR_NAMESPACE) logs -f statefulset.apps/elastic-namespace-operator

logs-global-operator:
	@ kubectl --namespace=$(GLOBAL_OPERATOR_NAMESPACE) logs -f statefulset.apps/elastic-global-operator

samples:
	@ echo "-> Pushing samples to Kubernetes cluster..."
	@ kubectl apply -f config/samples/kibana/kibana_es.yaml

# Display elasticsearch credentials of the first stack
show-credentials:
	@ echo "elastic:$$(kubectl get secret elasticsearch-sample-es-elastic-user -o json | jq -r '.data.elastic' | base64 -D)"


##########################################
##  --    K8s clusters bootstrap    --  ##
##########################################

cluster-bootstrap: install-crds

clean-k8s-cluster:
	kubectl delete --ignore-not-found=true  ValidatingWebhookConfiguration validating-webhook-configuration
	for ns in $(NAMESPACE_OPERATOR_NAMESPACE) $(GLOBAL_OPERATOR_NAMESPACE) $(MANAGED_NAMESPACE); do \
		echo "Deleting resources in $$ns"; \
		kubectl delete statefulsets -n $$ns --all; \
		kubectl delete deployments -n $$ns --all; \
		kubectl delete svc -n $$ns --all; \
		kubectl delete rc -n $$ns --all; \
		kubectl delete po -n $$ns --all; \
	done

## -- minikube

set-context-minikube:
	kubectl config use-context "minikube"
	$(eval KUBECTL_CLUSTER="minikube")

bootstrap-minikube:
	hack/minikube-cluster.sh
	$(MAKE) set-context-minikube cluster-bootstrap

## -- clouds

PROVIDER=$(shell test -f hack/deployer/config/provider && cat hack/deployer/config/provider)
DEPLOYER=./hack/deployer/deployer --plans-file=hack/deployer/config/plans.yml --config-file=hack/deployer/config/deployer-config-$(PROVIDER).yml

build-deployer:
	@ go build -mod=readonly -o ./hack/deployer/deployer ./hack/deployer/main.go

create-default-config:
ifeq ($(wildcard hack/deployer/config/deployer-config-$(PROVIDER).yml),)
	@ ./hack/deployer/deployer create defaultConfig --path=hack/deployer/config --provider=$(PROVIDER)
endif

setup-deployer: build-deployer
ifeq ($(PROVIDER),)
	$(MAKE) switch-gke
endif
	$(MAKE) create-default-config

get-deployer-config: setup-deployer
	@ $(DEPLOYER) get config

credentials: setup-deployer
	@ $(DEPLOYER) get credentials

set-context: credentials
	$(eval KUBECTL_CLUSTER=$($(DEPLOYER) get clusterName))

bootstrap-k8s: setup-deployer
	@ $(DEPLOYER) execute

bootstrap-cloud: bootstrap-k8s
	$(MAKE) cluster-bootstrap
ifeq ($(PSP), 1)
	$(MAKE) apply-psp
endif

delete-cloud: setup-deployer
	@ $(DEPLOYER) execute --operation=delete

switch-gke:
	@ echo "gke" > hack/deployer/config/provider

switch-aks:
	@ echo "aks" > hack/deployer/config/provider

switch-ocp:
	@ echo "ocp" > hack/deployer/config/provider

#################################
##  --    Docker images    --  ##
#################################

docker-build:
	docker build . \
		--build-arg GO_LDFLAGS='$(GO_LDFLAGS)' \
		--build-arg GO_TAGS='$(GO_TAGS)' \
		-t $(OPERATOR_IMAGE)

docker-push:
ifeq ($(REGISTRY), docker.elastic.co)
	@ docker login -u $(ELASTIC_DOCKER_LOGIN) -p $(ELASTIC_DOCKER_PASSWORD) push.docker.elastic.co
endif
ifeq ($(REGISTRY), eu.gcr.io)
	@ gcloud auth configure-docker --quiet
endif
ifeq ($(KUBECTL_CLUSTER), minikube)
	# use the minikube registry
	@ hack/registry.sh port-forward start
	docker push $(OPERATOR_IMAGE)
	@ hack/registry.sh port-forward stop
else
ifeq ($(REGISTRY), docker.elastic.co)
	@ docker tag $(OPERATOR_IMAGE) push.$(OPERATOR_IMAGE)
	@ docker push push.$(OPERATOR_IMAGE)
else
	@ docker push $(OPERATOR_IMAGE)
endif
endif

purge-gcr-images:
	@ for i in $(gcloud container images list-tags $(IMG) | tail +3 | awk '{print $$2}'); \
		do gcloud container images untag $(IMG):$$i; \
	done


###################################
##  --   End to end tests    --  ##
###################################

# can be overriden to eg. TESTS_MATCH=TestMutationMoreNodes to match a single test
TESTS_MATCH ?= "^Test"
E2E_IMG ?= $(IMG)-e2e-tests:$(TAG)
STACK_VERSION ?= 7.5.0
E2E_JSON ?= false
TEST_TIMEOUT ?= 5m

# Run e2e tests as a k8s batch job
e2e: build-operator-image e2e-docker-build e2e-docker-push e2e-run

# clean to remove irrelevant/build-breaking generated public keys
e2e-docker-build: clean
	docker build --build-arg E2E_JSON=$(E2E_JSON) -t $(E2E_IMG) -f test/e2e/Dockerfile .

e2e-docker-push:
	docker push $(E2E_IMG)

e2e-run:
	@go run test/e2e/cmd/main.go run \
		--operator-image=$(OPERATOR_IMAGE) \
		--e2e-image=$(E2E_IMG) \
		--test-regex=$(TESTS_MATCH) \
		--test-license=$(TEST_LICENSE) \
		--elastic-stack-version=$(STACK_VERSION) \
		--log-verbosity=$(LOG_VERBOSITY) \
		--log-to-file=$(E2E_JSON) \
		--test-timeout=$(TEST_TIMEOUT) \
		--monitoring-secrets=$(MONITORING_SECRETS)

e2e-generate-xml:
	@ gotestsum --junitfile e2e-tests.xml --raw-command cat e2e-tests.json

# Verify e2e tests compile with no errors, don't run them
e2e-compile:
	go test ./test/e2e/... -run=dryrun > /dev/null

# Run e2e tests locally (not as a k8s job), with a custom http dialer
# that can reach ES services running in the k8s cluster through port-forwarding.
LOCAL_E2E_CTX:=/tmp/e2e-local.json

e2e-local:
	@go run test/e2e/cmd/main.go run \
		--test-run-name=e2e \
		--test-context-out=$(LOCAL_E2E_CTX) \
		--test-license=$(TEST_LICENSE) \
		--elastic-stack-version=$(STACK_VERSION) \
		--auto-port-forwarding \
		--local \
		--log-verbosity=$(LOG_VERBOSITY) \
		--ignore-webhook-failures \
		--test-timeout=$(TEST_TIMEOUT)
	@E2E_JSON=$(E2E_JSON) test/e2e/run.sh -run "$(TESTS_MATCH)" -args -testContextPath $(LOCAL_E2E_CTX)

##########################################
##  --    Continuous integration    --  ##
##########################################
ci-check: check-license-header lint generate check-local-changes

ci: unit_xml integration_xml docker-build

# Run e2e tests in a dedicated cluster.
ci-e2e: e2e-compile run-deployer install-crds apply-psp e2e

run-deployer: build-deployer
	./hack/deployer/deployer execute --plans-file hack/deployer/config/plans.yml --config-file deployer-config.yml

ci-release: clean ci-check build-operator-image
	@ echo $(OPERATOR_IMAGE) was pushed!

##########################
##  --   Helpers    --  ##
##########################

check-requisites:
	@ hack/check-requisites.sh

check-license-header:
	./build/check-license-header.sh

# Check if some changes exist in the workspace (eg. `make generate` added some changes)
check-local-changes:
	@ [[ "$$(git status --porcelain)" == "" ]] \
		|| ( echo -e "\nError: dirty local changes"; git status --porcelain; exit 1 )

# Runs small Go tool to validate syntax correctness of Jenkins pipelines
validate-jenkins-pipelines:
	@ go run ./hack/pipeline-validator/main.go

#########################
# Kind specific targets #
#########################
KIND_NODES ?= 3
KIND_NODE_IMAGE ?= kindest/node:v1.15.3
KIND_CLUSTER_NAME ?= eck

kind-node-variable-check:
ifndef KIND_NODE_IMAGE
	$(error KIND_NODE_IMAGE is mandatory when using Kind)
endif

bootstrap-kind:
	KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME} \
		$(MAKE) kind-cluster-$(KIND_NODES)
	@ echo "Run the following command to update your current context:"
	@ echo "kubectl config set-context kind-${KIND_CLUSTER_NAME}"

## Start a kind cluster with just the CRDs, e.g.:
# "make kind-cluster-0 KIND_NODE_IMAGE=kindest/node:v1.15.0" # start a one node cluster
# "make kind-cluster-3 KIND_NODE_IMAGE=kindest/node:v1.15.0" to start a 1 master + 3 nodes cluster
kind-cluster-%: export NODE_IMAGE = ${KIND_NODE_IMAGE}
kind-cluster-%: export CLUSTER_NAME = ${KIND_CLUSTER_NAME}
kind-cluster-%: kind-node-variable-check
	./hack/kind/kind.sh \
		--nodes "${*}" \
		make install-crds

## Same as above but build and deploy the operator image
kind-with-operator-%: export NODE_IMAGE = ${KIND_NODE_IMAGE}
kind-with-operator-%: export CLUSTER_NAME = ${KIND_CLUSTER_NAME}
kind-with-operator-%: kind-node-variable-check docker-build
	./hack/kind/kind.sh \
		--load-images $(OPERATOR_IMAGE) \
		--nodes "${*}" \
		make install-crds apply-operators

## Run all the e2e tests in a Kind cluster
set-kind-e2e-image:
ifneq ($(ECK_IMAGE),)
	$(eval OPERATOR_IMAGE=$(ECK_IMAGE))
	@docker pull $(OPERATOR_IMAGE)
else
	$(MAKE) go-generate docker-build
endif

kind-e2e: export KUBECONFIG = ${HOME}/.kube/kind-config-eck-e2e
kind-e2e: export NODE_IMAGE = ${KIND_NODE_IMAGE}
kind-e2e: kind-node-variable-check set-kind-e2e-image e2e-docker-build
	./hack/kind/kind.sh \
		--load-images $(OPERATOR_IMAGE),$(E2E_IMG) \
		--nodes 3 \
		make e2e-run OPERATOR_IMAGE=$(OPERATOR_IMAGE)

## Cleanup
delete-kind:
	./hack/kind/kind.sh --stop
