# Cluster Setup

This has only been tested and run on macOS. If you're trying this out with Linux and Windows you will have to adapt some commands. 

### Prerequisites
* **[AWS CLI](https://aws.amazon.com/documentation/cli/)** to manage AWS resources
	* `pip install --upgrade --user awscli`
	* `aws configure`

* **[terraform](https://www.terraform.io/)** to create a DB on AWS
	* `brew install terraform`j

* **[jq](https://stedolan.github.io/jq/)** to parse JSON results returned by the AWS CLI
	* `brew install jq`

* **[chronic](https://joeyh.name/code/moreutils/)** to suppress output unless there's a non-zero exit code
	* `brew install moreutils`

* **[envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html)** to replace environment variables in templates
	* `brew install gettext`

* **[kops](https://github.com/kubernetes/kops/)** to create the Kubernetes cluster
	* `brew install kops`

* **[kubectl](https://kubernetes.io/)** to manage Kubernetes resources
	* `brew install kubernetes-cli`

	
## How does it work?

#### 1. Create Cluster
The first script `1-create-cluster.sh` will:

* Generate a new ssh key for the cluster
* Create S3 buckets for the cluster configuration
* Create IAM groups, users and policies for `kops`
* Create the Kubernetes cluster with `kops`
* Extract the `kubeconfig` from the new cluster
* Encrypt the `kubeconfig` with `openssl`
* Upload the encrypted `kubeconfig` to S3

#### 2. Create Database
The second script `2-create-database.sh` will:

* Set up the Database credentials
* Create a PostGres database with AWS RDS
* Create an S3 bucket for the database config
* Encrypt the terraform DB state with `openssl`
* Upload the encrypted terraform DB state to S3
* Generate a Kubernetes secret for the backend services to be able to connect to the DB

#### 3. Create Services
The third script `3-create-services.sh` will:

* Set up a new subdomain for the cluster
* Create all specified kubernetes deployments and services
* Create a Kubernetes ingress controller and ingress resource
* Set up SSL using [kube-lego](https://github.com/jetstack/kube-lego) which uses [Let's Encrypt](https://letsencrypt.org/) internally
* Set up monitoring and logging services
	* [Kubernetes Dashboard](https://github.com/kubernetes/dashboard)
	* [ELK stack](https://github.com/kubernetes/kops/tree/master/addons/logging-elasticsearch)
	* [Heapster](https://github.com/kubernetes/kops/tree/master/addons/monitoring-standalone)
	* [Kubernetes Operational View](https://github.com/hjacobs/kube-ops-view)
* Set up autoscaling through kops' [cluster-autoscaler addon](https://github.com/kubernetes/kops/tree/master/addons/cluster-autoscaler)