---
author: sn0rt
comments: true
date: 2019-03-29
layout: post
title:  cloud provider summary
tag: k8s
---

​	cloud  controller manager 是可插拔的，它运行新的cloud provider 简单方便的与Kubernetes集成。

​	cloud provider 启动从new 一个 cloud manager command 开始

```go
func main() {
...
   command := app.NewCloudControllerManagerCommand()
...
}
```

​	Run 函数是k8s contrller manager 定义的关键入口，在NewCloudControllerManagerCommand中被调用，参数是一个CompletedConfig,第二个参数是stopCh。

```go
// NewCloudControllerManagerCommand creates a *cobra.Command object with default parameters
func NewCloudControllerManagerCommand() *cobra.Command {
   s, err := options.NewCloudControllerManagerOptions()
...
         if err := Run(c.Complete(), wait.NeverStop); err != nil {
...
   return cmd
}
```

​	Run函数的实现，主要是做些controller启动前的准备工作，比如锁的获取，实际做controller启动的是调用startControllers。

```go

// Run runs the ExternalCMServer.  This should never exit.
func Run(c *cloudcontrollerconfig.CompletedConfig, stopCh <-chan struct{}) error {
...
	run := func(ctx context.Context) {
		if err := startControllers(c, ctx.Done(), cloud); err != nil {
			glog.Fatalf("error running controllers: %v", err)
		}
	}
...
	// Lock required for leader election
	rl, err := resourcelock.New(c.ComponentConfig.Generic.LeaderElection.ResourceLock,
		"kube-system",
		"cloud-controller-manager",
		c.LeaderElectionClient.CoreV1(),
		resourcelock.ResourceLockConfig{
			Identity:      id,
			EventRecorder: c.EventRecorder,
		})
	if err != nil {
		glog.Fatalf("error creating lock: %v", err)
	}
....
}
```

在startcontroller中实际启动的controller如下：CloudNodeController，PersistentVolumeLabelController，RouteController，serviceController。

CloudNodeController 负责初始化k8s中node与云上的信息。

PersistentVolumeLabelController 负责给PV打Label，保证存储不会被跨区挂载。

RouteController 用来创建路由解决不通node上pod的互通问题。

serviceController 用来创建云厂商的负载均衡。

```go

// startControllers starts the cloud specific controller loops.
func startControllers(c *cloudcontrollerconfig.CompletedConfig, stop <-chan struct{}, cloud cloudprovider.Interface) error {
...
	if cloud != nil {
		// Initialize the cloud provider with a reference to the clientBuilder
		cloud.Initialize(c.ClientBuilder)
	}
	// Start the CloudNodeController
	nodeController := cloudcontrollers.NewCloudNodeController(
		c.SharedInformers.Core().V1().Nodes(),
		client("cloud-node-controller"), cloud,
		c.ComponentConfig.KubeCloudShared.NodeMonitorPeriod.Duration,
		c.ComponentConfig.NodeStatusUpdateFrequency.Duration)

	nodeController.Run(stop)
...
	// Start the PersistentVolumeLabelController
	pvlController := cloudcontrollers.NewPersistentVolumeLabelController(client("pvl-controller"), cloud)
	go pvlController.Run(5, stop)
...
	// Start the service controller
	serviceController, err := servicecontroller.New(
		cloud,
		client("service-controller"),
		c.SharedInformers.Core().V1().Services(),
		c.SharedInformers.Core().V1().Nodes(),
		c.ComponentConfig.KubeCloudShared.ClusterName,
	)
	if err != nil {
		glog.Errorf("Failed to start service controller: %v", err)
	} else {
		go serviceController.Run(stop, int(c.ComponentConfig.ServiceController.ConcurrentServiceSyncs))
...

	// If CIDRs should be allocated for pods and set on the CloudProvider, then start the route controller
	if c.ComponentConfig.KubeCloudShared.AllocateNodeCIDRs && c.ComponentConfig.KubeCloudShared.ConfigureCloudRoutes {
		if routes, ok := cloud.Routes(); !ok {
			glog.Warning("configure-cloud-routes is set, but cloud provider does not support routes. Will not configure cloud provider routes.")
		} else {
			var clusterCIDR *net.IPNet
			if len(strings.TrimSpace(c.ComponentConfig.KubeCloudShared.ClusterCIDR)) != 0 {
				_, clusterCIDR, err = net.ParseCIDR(c.ComponentConfig.KubeCloudShared.ClusterCIDR)
				if err != nil {
					glog.Warningf("Unsuccessful parsing of cluster CIDR %v: %v", c.ComponentConfig.KubeCloudShared.ClusterCIDR, err)
				}
			}

			routeController := routecontroller.New(routes, client("route-controller"), c.SharedInformers.Core().V1().Nodes(), c.ComponentConfig.KubeCloudShared.ClusterName, clusterCIDR)
			go routeController.Run(stop, c.ComponentConfig.KubeCloudShared.RouteReconciliationPeriod.Duration)
...
}

```