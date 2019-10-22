---
author: sn0rt
comments: true
date: 2019-10-20
layout: post
title:  cluster api v1alpha2 之 cluster
tag: k8s
---

因为最近工作需要, 调研了 cluster api provider aws. 
整理调研过程中的知识如下:

manager cluster 是一个注册了多个 crd 并运行三个 controller 的普通 k8s 集群.

三个 controller 分别是:
cabpk-controller-manager 核心功能是用来生产集群证书统一签发, 核心进程的参数下发.
capa-controller-manager 核心功能是和 aws 沟通, 负责 CRUD 云上资源.
capi-controller-manager 核心功能是确定 cluster api group 和集群公用资源.

## 用户通过 CAPA 脚本渲染 spec

目前 cluster api 使用过 shell 脚本渲染出基本的集群模版文件,并由用户主动发送的到 manager cluster 中.
渲染出的 cluster 资源如下, 看到 api version 是 v1alpha2 , 下面支持 amazon cni 是自己适配开发的.
cluster crd 由 capi-controller-manager 中的 cluster 负责调协工作.

```yaml
apiVersion: cluster.x-k8s.io/v1alpha2
kind: Cluster
metadata:
  annotations:
    cluster.k8s.io/network-cni: AmazonVPC
  name: testnetwork3
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.66.0.0/24
    services:
      cidrBlocks:
      - 192.168.0.0/16
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha2
    kind: AWSCluster
    name: testnetwork3
    namespace: default   
```

渲染出的 awscluster 资源如下, 声明式的告诉进行capa-controller-manager 中的  awscluster controller 进行调协 时要按照yaml里面描述创建子网信息.

之所以要创建6个子网是计划通过 aws 来投放 HA 的 kubernetes 集群, 每个区域放一个 master apiserver.

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha2
kind: AWSCluster
metadata:
  name: testnetwork3
  namespace: default
spec:
  networkSpec:
    subnets:
    - availabilityZone: us-east-2a
      cidrBlock: 10.66.0.0/27
      isPublic: true
    - availabilityZone: us-east-2a
      cidrBlock: 10.66.0.32/27
      isPublic: false
    - availabilityZone: us-east-2b
      cidrBlock: 10.66.0.64/27
      isPublic: true
    - availabilityZone: us-east-2b
      cidrBlock: 10.66.0.96/27
      isPublic: false
    - availabilityZone: us-east-2c
      cidrBlock: 10.66.0.128/27
      isPublic: true
    - availabilityZone: us-east-2c
      cidrBlock: 10.66.0.160/27
      isPublic: false
    vpc:
      cidrBlock: 10.66.0.0/24
  region: us-east-2
  sshKeyName: guohao
```

上面两个文件和在一起就是 CAPA 官方的渲染脚本输出的 cluster.yaml 文件的全部内容了, 虽然是一个文件2个yaml, 但是确涉及到了 2 个 controller manager 中的 awscluster controller 和 cluster controller.


## cluster controller 如何工作的

在 capa 中 cluster controller 不能独立与 awscluster controller 工作, 两个组建之间的协作流程如下图.

![cluster-controller-and-awscluster-controller](https://github.com/kubernetes-sigs/cluster-api/raw/master/docs/proposals/images/cluster-spec-crds/figure1.png)

> Figure 1 presents the sequence of actions involved in provisioning a cluster, highlighting the coordination required between the CAPI cluster controller and the provider infrastructure controller.
>
> The creation of the Cluster and provider infrastructure objects are independent events. It is expected that the cluster infrastructure object to be created before the cluster object and the reference be set to in the cluster object at creation time.
>
> When a provider infrastructure object is created, the provider's controller will do nothing unless its owner reference is set to a cluster object.
>
> When the cluster object is created, the cluster controller will retrieve the infrastructure object. If the object has not been seen before, it will start watching it. Also, if the object's owner is not set, it will set to the Cluster object.
>
> When an infrastructure object is updated, the provider controller will check the owner reference. If it is set, it will retrieve the cluster object to obtain the required cluster specification and starts the provisioning process. When the process finishes, it sets the Infrastructure.Status.Ready to true.
>
> When the cluster controller detects the Infrastructure.Status.Ready is set to true, it updates Cluster.Status.APIEndpoints from Infrastructure.Status.APIEndpoints and sets Cluster.Status.InfrastructureReady to true.
>

上述流程还是比较明了的.


## cluster controller 实现

目前 controller 的开发都是使用了 kubebuilder 那一套脚手架了, controller 开发模式直接大同小异了. 核心就是一个函数 `reconcile` .

核心函数的核心逻辑代码如下, 三个子资源的 `reconcile`, cluster controller 整个流程并没有实际创建什么东西,仅仅是对账信息, 组装流程.

```go
// reconcile handles cluster reconciliation.
func (r *ClusterReconciler) reconcile(ctx context.Context, cluster *clusterv1.Cluster) (ctrl.Result, error) {
...
	// Call the inner reconciliation methods.
	reconciliationErrors := []error{
		r.reconcileInfrastructure(ctx, cluster),
		r.reconcileKubeconfig(ctx, cluster),
		r.reconcileControlPlaneInitialized(ctx, cluster),
	}
...
}
```

`reconcileInfrastructure`  的实现就像之前提议里面描述一样, 因为并不涉及到实际的资源创建.
只是从 awscluster 的 yaml 中获取 infrastructure 和 apiserver endpoint 信息.

```go
// reconcileInfrastructure reconciles the Spec.InfrastructureRef object on a Cluster.
func (r *ClusterReconciler) reconcileInfrastructure(ctx context.Context, cluster *clusterv1.Cluster) error {
	logger := r.Log.WithValues("cluster", cluster.Name, "namespace", cluster.Namespace)

	if cluster.Spec.InfrastructureRef == nil {
		return nil
	}

	// Call generic external reconciler.
	infraConfig, err := r.reconcileExternal(ctx, cluster, cluster.Spec.InfrastructureRef)
	if err != nil {
		return err
	}

	// There's no need to go any further if the Cluster is marked for deletion.
	if !infraConfig.GetDeletionTimestamp().IsZero() {
		return nil
	}

	// Determine if the infrastructure provider is ready.
	if !cluster.Status.InfrastructureReady {
		ready, err := external.IsReady(infraConfig)
		if err != nil {
			return err
		} else if !ready {
			logger.V(3).Info("Infrastructure provider is not ready yet")
			return nil
		}
		cluster.Status.InfrastructureReady = true
	}

	// Get and parse Status.APIEndpoint field from the infrastructure provider.
	if len(cluster.Status.APIEndpoints) == 0 {
		if err := util.UnstructuredUnmarshalField(infraConfig, &cluster.Status.APIEndpoints, "status", "apiEndpoints"); err != nil {
			return errors.Wrapf(err, "failed to retrieve Status.APIEndpoints from infrastructure provider for Cluster %q in namespace %q",
				cluster.Name, cluster.Namespace)
		} else if len(cluster.Status.APIEndpoints) == 0 {
			return errors.Wrapf(err, "retrieved empty Status.APIEndpoints from infrastructure provider for Cluster %q in namespace %q",
				cluster.Name, cluster.Namespace)
		}
	}

	return nil
}
```

kubeconfig 的信息对账,  如果没有有现成的 kubeconfig 那就创建一个现成的, 附上一个从 manager cluster 中获取 kubeconfig 的指令.

```shell
kubectl --namespace=default get secret $CLUSTER_NAME-kubeconfig -o json | jq -r .data.value | base64 --decode  > $CLUSTER_NAME-kubeconfig
```

```go

func (r *ClusterReconciler) reconcileKubeconfig(ctx context.Context, cluster *clusterv1.Cluster) error {
	if len(cluster.Status.APIEndpoints) == 0 {
		return nil
	}

	_, err := secret.Get(r.Client, cluster, secret.Kubeconfig)
	switch {
	case apierrors.IsNotFound(err):
		if err := kubeconfig.CreateSecret(ctx, r.Client, cluster); err != nil {
...
	return nil
}

```

如果有一个 master 节点是初始化完成, 这个函数就不会发生任何错误.

```go
func (r *ClusterReconciler) reconcileControlPlaneInitialized(ctx context.Context, cluster *clusterv1.Cluster) error {
	logger := r.Log.WithValues("cluster", cluster.Name, "namespace", cluster.Namespace)

	if cluster.Status.ControlPlaneInitialized {
		return nil
	}

	machines, err := getActiveMachinesInCluster(ctx, r.Client, cluster.Namespace, cluster.Name)
	if err != nil {
		logger.Error(err, "Error getting machines in cluster")
		return err
	}

	for _, m := range machines {
		if util.IsControlPlaneMachine(m) && m.Status.NodeRef != nil {
			cluster.Status.ControlPlaneInitialized = true
			return nil
		}
	}

	return nil
}
```


## awscluster controller 如何工作的

下面就是 aws cluster controller 的核心逻辑

```go
// TODO(ncdc): should this be a function on ClusterScope?
func reconcileNormal(clusterScope *scope.ClusterScope) (reconcile.Result, error) {
	clusterScope.Info("Reconciling AWSCluster")

	awsCluster := clusterScope.AWSCluster

	// If the AWSCluster doesn't have our finalizer, add it.
	if !util.Contains(awsCluster.Finalizers, infrav1.ClusterFinalizer) {
		awsCluster.Finalizers = append(awsCluster.Finalizers, infrav1.ClusterFinalizer)
	}

	ec2Service := ec2.NewService(clusterScope)
	elbService := elb.NewService(clusterScope)

	if err := ec2Service.ReconcileNetwork(); err != nil { // 基础网络组网
		return reconcile.Result{}, errors.Wrapf(err, "failed to reconcile network for AWSCluster %s/%s", awsCluster.Namespace, awsCluster.Name)
	}

	if err := ec2Service.ReconcileBastion(); err != nil { // vpc 跳板机的创建
		return reconcile.Result{}, errors.Wrapf(err, "failed to reconcile bastion host for AWSCluster %s/%s", awsCluster.Namespace, awsCluster.Name)
	}

	if err := elbService.ReconcileLoadbalancers(); err != nil { // apiserver 的 lb 创建
		return reconcile.Result{}, errors.Wrapf(err, "failed to reconcile load balancers for AWSCluster %s/%s", awsCluster.Namespace, awsCluster.Name)
	}

	if awsCluster.Status.Network.APIServerELB.DNSName == "" {
		clusterScope.Info("Waiting on API server ELB DNS name")
		return reconcile.Result{RequeueAfter: 15 * time.Second}, nil
	}

	// Set APIEndpoints so the Cluster API Cluster Controller can pull them
	// TODO: should we get the Port from the first listener on the ELB?
	awsCluster.Status.APIEndpoints = []infrav1.APIEndpoint{
		{
			Host: awsCluster.Status.Network.APIServerELB.DNSName,
			Port: int(clusterScope.APIServerPort()),
		},
	}

	// No errors, so mark us ready so the Cluster API Cluster Controller can pull it
	awsCluster.Status.Ready = true

	return reconcile.Result{}, nil
}
```

`ReconcileNetwork` 就是基础组网的逻辑, 这个逻辑会按照你传入的 network 信息进行最基本的 vpc 创建, 定制化的 subnet 创建.

```go
func (s *Service) ReconcileNetwork() (err error) {
	s.scope.V(2).Info("Reconciling network for cluster", "cluster-name", s.scope.Cluster.Name, "cluster-namespace", s.scope.Cluster.Namespace)

	// VPC.
	if err := s.reconcileVPC(); err != nil {
		return err
	}

	// Subnets.
	if err := s.reconcileSubnets(); err != nil {
		return err
	}

	// Internet Gateways.
	if err := s.reconcileInternetGateways(); err != nil {
		return err
	}

	// NAT Gateways.
	if err := s.reconcileNatGateways(); err != nil { // 这里有点问题, 按照我之前 spec 描述就会创建出三个NATGW, 有点浪费了.
		return err
	}

	// Routing tables.
	if err := s.reconcileRouteTables(); err != nil {
		return err
	}

	// Security groups.
	if err := s.reconcileSecurityGroups(); err != nil {
		return err
	}

	s.scope.V(2).Info("Reconcile network completed successfully")
	return nil
}
```

其余两个流程过于简单就不单独概述了, 自行浏览代码即可.