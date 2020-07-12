use crate::core::{
    Node as CoreNode,
    Cluster as CoreCluster,
};
use core::{
    pin::Pin,
    ptr::NonNull,
};

#[repr(C)]
#[derive(Debug, Default)]
pub struct Cluster {
    inner: CoreCluster,
}

impl From<Pin<&mut Node>> for Cluster {
    fn from(node: Pin<&mut Node>) -> Self {
        Self {
            inner: CoreCluster::from(unsafe {
                let node = Pin::into_inner_unchecked(node);
                Pin::new_unchecked(&mut node.inner)
            }),
        }
    }
}

impl Cluster {
    pub const fn new() -> Self {
        Self { inner: CoreCluster::new() }
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn push(&mut self, node: Pin<&mut Node>) {
        self.push_many(Self::from(node))
    }

    pub fn push_many(&mut self, other: Self) {
        self.inner.push_many(other.inner)
    }

    pub fn pop(&mut self) -> Option<NonNull<Node>> {
        self.inner.pop().map(|core_node_ptr| unsafe {
            let node_ptr = core_node_ptr.as_ptr() as *mut Node;
            NonNull::new_unchecked(node_ptr)
        })
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Node>> + 'a {
        self.inner.iter().map(|core_node| unsafe {
            let node_ptr = (&*core_node) as *const _ as *mut Node;
            Pin::new_unchecked(&*node_ptr)
        })
    }
}

#[repr(C)]
pub struct Node {
    inner: CoreNode,
    numa_node: Option<u32>,
    cpu_affinity: Option<(u16, u16)>,
}

impl Node {

}