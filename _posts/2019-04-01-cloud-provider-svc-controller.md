---
author: sn0rt
comments: true
date: 2019-04-01
layout: post
title:  cloud provider Service Controller
tag: k8s
---

​	service controller负责观察k8s中service资源的创建，更新和删除事件。并基于当前k8s中的service状态去云上配置负载均衡，保证云上的负载均与serivce资源描述相一致。

​	service controller 在 cloud contorller 中的一个模块随cloud controller启动，可以通过启动new service controller 参数可以观测到，service controller 是通过观察service 和 node资源来工作的。

```go
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
   time.Sleep(wait.Jitter(c.ComponentConfig.Generic.ControllerStartInterval.Duration, ControllerStartJitter))
}
```

​	new 函数的实现如下，核心是流程是通过list/watch机制来观测service 的event，然后触发enqueue的函数，再通过sync woker从wrok queue中取出item处理云上lb的绑定逻辑。

```go
// New returns a new service controller to keep cloud provider service resources
// (like load balancers) in sync with the registry.
func New(
   cloud cloudprovider.Interface,
   kubeClient clientset.Interface,
   serviceInformer coreinformers.ServiceInformer,
   nodeInformer coreinformers.NodeInformer,
   clusterName string,
) (*ServiceController, error) {
   broadcaster := record.NewBroadcaster()
   broadcaster.StartLogging(glog.Infof)
   broadcaster.StartRecordingToSink(&v1core.EventSinkImpl{Interface: kubeClient.CoreV1().Events("")})
   recorder := broadcaster.NewRecorder(scheme.Scheme, v1.EventSource{Component: "service-controller"})

   if kubeClient != nil && kubeClient.CoreV1().RESTClient().GetRateLimiter() != nil {
      if err := metrics.RegisterMetricAndTrackRateLimiterUsage("service_controller", kubeClient.CoreV1().RESTClient().GetRateLimiter()); err != nil {
         return nil, err
      }
   }

   s := &ServiceController{
      cloud:            cloud,
      knownHosts:       []*v1.Node{},
      kubeClient:       kubeClient,
      clusterName:      clusterName,
      cache:            &serviceCache{serviceMap: make(map[string]*cachedService)},
      eventBroadcaster: broadcaster,
      eventRecorder:    recorder,
      nodeLister:       nodeInformer.Lister(),
      nodeListerSynced: nodeInformer.Informer().HasSynced,
      queue:            workqueue.NewNamedRateLimitingQueue(workqueue.NewItemExponentialFailureRateLimiter(minRetryDelay, maxRetryDelay), "service"),
   }

   serviceInformer.Informer().AddEventHandlerWithResyncPeriod(
      cache.ResourceEventHandlerFuncs{
         AddFunc: s.enqueueService,
         UpdateFunc: func(old, cur interface{}) {
            oldSvc, ok1 := old.(*v1.Service)
            curSvc, ok2 := cur.(*v1.Service)
            if ok1 && ok2 && s.needsUpdate(oldSvc, curSvc) {
               s.enqueueService(cur)
            }
         },
         DeleteFunc: s.enqueueService,
      },
      serviceSyncPeriod,
   )
   s.serviceLister = serviceInformer.Lister()
   s.serviceListerSynced = serviceInformer.Informer().HasSynced

   if err := s.init(); err != nil {
      return nil, err
   }
   return s, nil
}
```

​	service通过形如namespace+serivce名字的key放入work queue，而syncService函数根据key取出service进行实际的处理操作，如果操作完成过后从work queue 中调用queue.done(key)移除掉。

```go
func (s *ServiceController) processNextWorkItem() bool {
   key, quit := s.queue.Get()
   if quit {
      return false
   }
   defer s.queue.Done(key)

   err := s.syncService(key.(string))
   if err == nil {
      s.queue.Forget(key)
      return true
   }

   runtime.HandleError(fmt.Errorf("error processing service %v (will retry): %v", key, err))
   s.queue.AddRateLimited(key)
   return true
}
```

​	之所以service 要一个额外的work queue 有原因的，其一是因为云上lb的实际绑定解绑操作相对于单纯的serivce声明要慢很多，其二是当service从k8s中删除的时候就真的被从etcd中移除了，这个时候从缓存里面找个删除对应公网lb的关键参数。

​	这个才是service controller的核心逻辑，这里会确认service是删除还是更新。

```go
// syncService will sync the Service with the given key if it has had its expectations fulfilled,
// meaning it did not expect to see any more of its pods created or deleted. This function is not meant to be
// invoked concurrently with the same key.
func (s *ServiceController) syncService(key string) error {
   startTime := time.Now()
   var cachedService *cachedService
   defer func() {
      glog.V(4).Infof("Finished syncing service %q (%v)", key, time.Since(startTime))
   }()

   namespace, name, err := cache.SplitMetaNamespaceKey(key)
   if err != nil {
      return err
   }

   // service holds the latest service info from apiserver
   service, err := s.serviceLister.Services(namespace).Get(name)
   switch {
   case errors.IsNotFound(err):
      // service absence in store means watcher caught the deletion, ensure LB info is cleaned
      glog.Infof("Service has been deleted %v. Attempting to cleanup load balancer resources", key)
      err = s.processServiceDeletion(key)
   case err != nil:
      glog.Infof("Unable to retrieve service %v from store: %v", key, err)
   default:
      cachedService = s.cache.getOrCreate(key)
      err = s.processServiceUpdate(cachedService, service, key)
   }

   return err
}
```

​	看一下处理service update的核心逻辑，

```go
// processServiceUpdate operates loadbalancers for the incoming service accordingly.
// Returns an error if processing the service update failed.
func (s *ServiceController) processServiceUpdate(cachedService *cachedService, service *v1.Service, key string) error {
   if cachedService.state != nil {
       // 如果是同名字但是UID不一样
       // 会被确认是不同的 serivice 则这个lb会被删除。
      if cachedService.state.UID != service.UID {
         err := s.processLoadBalancerDelete(cachedService, key)
         if err != nil {
            return err
         }
      }
   }
   // cache the service, we need the info for service deletion
   cachedService.state = service
   err := s.createLoadBalancerIfNeeded(key, service)
   if err != nil {
      eventType := "CreatingLoadBalancerFailed"
      message := "Error creating load balancer (will retry): "
      if !wantsLoadBalancer(service) {
         eventType = "CleanupLoadBalancerFailed"
         message = "Error cleaning up load balancer (will retry): "
      }
      message += err.Error()
      s.eventRecorder.Event(service, v1.EventTypeWarning, eventType, message)
      return err
   }
   // Always update the cache upon success.
   // NOTE: Since we update the cached service if and only if we successfully
   // processed it, a cached service being nil implies that it hasn't yet
   // been successfully processed.
   s.cache.set(key, cachedService)

   return nil
}
```

​	根据实际情况判断是更新，还是创建云上lb资源。

```go
// createLoadBalancerIfNeeded ensures that service's status is synced up with loadbalancer
// i.e. creates loadbalancer for service if requested and deletes loadbalancer if the service
// doesn't want a loadbalancer no more. Returns whatever error occurred.
func (s *ServiceController) createLoadBalancerIfNeeded(key string, service *v1.Service) error {
   // Note: It is safe to just call EnsureLoadBalancer.  But, on some clouds that requires a delete & create,
   // which may involve service interruption.  Also, we would like user-friendly events.

   // Save the state so we can avoid a write if it doesn't change
   previousState := v1helper.LoadBalancerStatusDeepCopy(&service.Status.LoadBalancer)
   var newState *v1.LoadBalancerStatus
   var err error
	// 针对Type变更,要做云的lb清理
   if !wantsLoadBalancer(service) {
      _, exists, err := s.balancer.GetLoadBalancer(context.TODO(), s.clusterName, service)
      if err != nil {
         return fmt.Errorf("error getting LB for service %s: %v", key, err)
      }
      if exists {
         glog.Infof("Deleting existing load balancer for service %s that no longer needs a load balancer.", key)
         s.eventRecorder.Event(service, v1.EventTypeNormal, "DeletingLoadBalancer", "Deleting load balancer")
         if err := s.balancer.EnsureLoadBalancerDeleted(context.TODO(), s.clusterName, service); err != nil {
            return err
         }
         s.eventRecorder.Event(service, v1.EventTypeNormal, "DeletedLoadBalancer", "Deleted load balancer")
      }

      newState = &v1.LoadBalancerStatus{}
   } else {
      glog.V(2).Infof("Ensuring LB for service %s", key)

      // TODO: We could do a dry-run here if wanted to avoid the spurious cloud-calls & events when we restart

      s.eventRecorder.Event(service, v1.EventTypeNormal, "EnsuringLoadBalancer", "Ensuring load balancer")
	// 这个地方是service更新更新的核心逻辑
      newState, err = s.ensureLoadBalancer(service)
      if err != nil {
         return fmt.Errorf("failed to ensure load balancer for service %s: %v", key, err)
      }
      s.eventRecorder.Event(service, v1.EventTypeNormal, "EnsuredLoadBalancer", "Ensured load balancer")
   }

   // Write the state if changed
   // TODO: Be careful here ... what if there were other changes to the service?
   if !v1helper.LoadBalancerStatusEqual(previousState, newState) {
      // Make a copy so we don't mutate the shared informer cache
      service = service.DeepCopy()

      // Update the status on the copy
      service.Status.LoadBalancer = *newState

      if err := s.persistUpdate(service); err != nil {
         // TODO: This logic needs to be revisited. We might want to retry on all the errors, not just conflicts.
         if errors.IsConflict(err) {
            return fmt.Errorf("not persisting update to service '%s/%s' that has been changed since we received it: %v", service.Namespace, service.Name, err)
         }
         runtime.HandleError(fmt.Errorf("failed to persist service %q updated status to apiserver, even after retries. Giving up: %v", key, err))
         return nil
      }
   } else {
      glog.V(2).Infof("Not persisting unchanged LoadBalancerStatus for service %s to registry.", key)
   }

   return nil
}
```

```go
func (s *ServiceController) ensureLoadBalancer(service *v1.Service) (*v1.LoadBalancerStatus, error) {
...
    // 基本就是调用这个函数
   return s.balancer.EnsureLoadBalancer(context.TODO(), s.clusterName, service, nodes)
}
```

​	下面是抽象给cloud provider实现的接口, 由serivce controller来统一调用，EnsureLoadBalancer是最核心的函数，一般云厂商的实现方式就是将他们的公网LB产品和k8s的LoadBalancer type的service结合起来。

```go
// LoadBalancer is an abstract, pluggable interface for load balancers.
type LoadBalancer interface {
   // TODO: Break this up into different interfaces (LB, etc) when we have more than one type of service
   // GetLoadBalancer returns whether the specified load balancer exists, and
   // if so, what its status is.
   // Implementations must treat the *v1.Service parameter as read-only and not modify it.
   // Parameter 'clusterName' is the name of the cluster as presented to kube-controller-manager
   GetLoadBalancer(ctx context.Context, clusterName string, service *v1.Service) (status *v1.LoadBalancerStatus, exists bool, err error)
   // GetLoadBalancerName returns the name of the load balancer. Implementations must treat the
   // *v1.Service parameter as read-only and not modify it.
   GetLoadBalancerName(ctx context.Context, clusterName string, service *v1.Service) string
   // EnsureLoadBalancer creates a new load balancer 'name', or updates the existing one. Returns the status of the balancer
   // Implementations must treat the *v1.Service and *v1.Node
   // parameters as read-only and not modify them.
   // Parameter 'clusterName' is the name of the cluster as presented to kube-controller-manager
   EnsureLoadBalancer(ctx context.Context, clusterName string, service *v1.Service, nodes []*v1.Node) (*v1.LoadBalancerStatus, error)
   // UpdateLoadBalancer updates hosts under the specified load balancer.
   // Implementations must treat the *v1.Service and *v1.Node
   // parameters as read-only and not modify them.
   // Parameter 'clusterName' is the name of the cluster as presented to kube-controller-manager
   UpdateLoadBalancer(ctx context.Context, clusterName string, service *v1.Service, nodes []*v1.Node) error
   // EnsureLoadBalancerDeleted deletes the specified load balancer if it
   // exists, returning nil if the load balancer specified either didn't exist or
   // was successfully deleted.
   // This construction is useful because many cloud providers' load balancers
   // have multiple underlying components, meaning a Get could say that the LB
   // doesn't exist even if some part of it is still laying around.
   // Implementations must treat the *v1.Service parameter as read-only and not modify it.
   // Parameter 'clusterName' is the name of the cluster as presented to kube-controller-manager
   EnsureLoadBalancerDeleted(ctx context.Context, clusterName string, service *v1.Service) error
}
```
​	如果客户在k8s中创建LoadBalancer type的service，cloud proivder的EnsureLoadBalancer常见实现方式是，调用云上LB相关接口将LB及其必要的依赖资源创建出来，其LB对应的后端是serivce所属的集群内的k8s node*全部*节点，部分节点也可以的原因是因为收到流量的部分节点会通过kube-proxy的规则将流量二次转发[具体细节](../kube-proxy-iptables)。
​	当lb创建完成，后端绑定成功后，客户就可以通过访问公网类型的LB的VIP来访问Pod中的业务了。这个时候流量是先到云厂商的公网网关，然后流量通过LB到云厂商提供给k8s的node上，最后再由kube-proxy通过watch endpoint产生的转发规则讲流量运到pod中。