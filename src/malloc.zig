const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Heap = struct {
    allocator: Allocator,

    pub fn init(self: *Heap) void {
        self.allocator = Allocator {
            shrinkFn = shrink,
            .reallocRn = realloc,
        };
    }

    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
        const self = @fieldParentPtr(Heap, "allocator", allocator);
        const old_ptr = @ptrToInt(old_mem.ptr);

        // new_size of 0 means to free old_mem
        if (new_size == 0) {
            self.free(old_ptr);
            return old_mem;
        // try and resize in place if its smaller than its real usable size
        } else if (old_mem.len > 0 and new_size <= self.usableSize(old_ptr)) {
            return old_mem[0..new_size];
        }

        // otherwise alloc, copy and free as normal. old_mem.len of 0 means new allocation
        const new_mem = self.allocAligned(new_size, new_align) orelse return Allocator.Error.OutOfMemory;
        if (old_mem.len > 0) {
            @memcpy(new_mem.ptr, old_mem.ptr, old_mem.len);
            self.free(old_ptr);
        }
        return new_mem[0..new_size];
    }

    fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        // if the alignment's the same and its not a 50% waste, return the old_mem but sliced
        const self = @fieldParentPtr(Heap, "allocator", allocator);
        if (new_size <= old_mem.len and new_align <= old_align and new_size >= (old_mem.len / 2))
            return old_mem[0..new_size];

        // otherwise its more than a 50% waste and should be reallocated instead
        const new_mem = self.allocAligned(new_size, new_align) orelse return old_mem[0..new_size];
        @memcpy(new_mem.ptr, old_mem.ptr, old_mem.len);
        self.free(@ptrToInt(old_mem.ptr));
        return new_mem[0..new_size];
    }

    fn allocAligned(self: *Heap, size: usize, alignment: usize) ?[*]u8 {
        // alignment <= pointer size (most allocations) should take fast path
        if (alignment <= @alignOf(usize))
            return self.alloc(size);

        // try and see if theres an immeidate page block that has just the right alignment
        if (size <= Page.SMALL_MAX) {
            const small_page = self.getSmallPage(size);
            if (small_page.free != null and std.mem.isAligned(@ptrToInt(small_page.free), alignment))
                return self.allocFast(small_page, size);
        }

        // otherwise, over-allocate and align within the allocation
        const ptr = @ptrToInt(self.alloc(size + alignment - 1) orelse return null);
        Page.from(ptr).flags.data.has_aligned = true;
        return @intToPtr([*]u8, std.mem.alignForward(ptr, alignment))[0..size];
    }

    fn alloc(self: *Heap, size: usize) ?[*]u8 {
        if (size <= Page.SMALL_MAX) // __builtin_expect(_, 1)
            return self.allocFast(self.getSmallPage(size), size);
        return self.allocGeneric(size);
    }

    fn allocFast(self: *Heap, page: *Page, size: usize) ?[*]u8 {
        // fast path: get a block & pop from the free list
        const block = page.free orelse return self.allocGeneric(size);
        page.free = mi_block_next(page, block);
        page.used += 1;
        return @ptrCast([*]u8, block);
    }

    fn allocGeneric(self: *Heap, size: usize) ?[*]u8 {

    }

    fn free(self: *Heap, ptr: usize) void {
        const segment = Segment.from(ptr);
        const page = segment.pageOf(ptr);
        const is_local = segment.heap == self;
        
        if (page.flags.value == 0) {

        }
    }

    fn usableSize(self: *Heap, ptr: usize) usize {
        const segment = Segment.from(ptr);
        const page = segment.pageOf(ptr);

        // _mi_page_ptr_unalign(segment, page, ptr)
        // diff = ptr - _mi_page_start(segment, page, null)
        // return pyt - (diff % page.block_size)

        var size = page.block_size;
        if (page.flags.data.has_aligned)
            size -= ptr - _mi_page_ptr_unalign(segment, page, ptr);
        return size;
    }
};

const Segment = struct {

    pub fn from(ptr: usize) *Segment {

    }

    pub fn pageOf(self: *Segment, ptr: usize) *Page {

    }
};

const Page = extern struct {
    pub const SMALL_SIZE  = 8 * 1024 * @sizeOf(usize);
    pub const MEDIUM_SIZE = SMALL_SIZE * @sizeOf(usize);
    pub const LARGE_SIZE  = MEDIUM_SIZE * @sizeOf(usize);

    pub const SMALL_MAX  = ;
    pub const MEDIUM_MAX = ;
    pub const LARGE_MAX  = ;

    segment_index: u8,
    segment_in_use: u1,
    is_reset: u1,

    block_size: 

    pub fn from(ptr: usize) *Page {

    }
};

const Block = struct {
    pub const SIZE_CLASSES = 64;
    pub const SHIFT = @ctz(usize, @sizeOf(usize));

    next: ?*Block,
}