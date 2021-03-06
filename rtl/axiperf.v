////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axiperf
// {{{
// Project:	WB2AXIPSP: bus bridges and other odds and ends
//
// Purpose:	Measure the performance of a high speed AXI interface.  The
// {{{
//		following monitor requires connecting to both an AXI-lite slave
//	interface, as well as a second AXI interface as a monitor.  The AXI
//	monitor interface is read only, and (ideally) shouldn't be corrupted by
//	the inclusion of the AXI-lite interface on the same bus.
//
//	The core works by counting clock cycles in a fashion that should
//	supposedly make it easy to calculate 1) throughput, and 2) lag.
//	Moreover, the counters are arranged such that after the fact, the
//	various contributors to throughput can be measured and evaluted: was
//	the slave the holdup?  Or was it the master?
//
//	To use the core, connect it and build your design.  Then write a '3'
//	to register 15 (address 60).  Once the bus returns to idle, the core
//	will begin capturing data and statistics.  When done, write a '0' to
//	the same register.  This will create a stop request.  Once the bus
//	comes to a stop, the core will stop accumulating values into its
//	statistics.  Those statistics can then be read out from the AXI-lite
//	bus and analyzed.
// }}}
// Goals:
// {{{
//	My two biggest goals are to measure throughput and lag.  Defining those
//	two measures, of course, is half the battle.   The other half of the
//	battle is knowing which side to blame for any particular issue.
//
//	Let's start with the total time required for any transaction.  This
//	equals the time from the indication of a request to the last response.
//	We'll use a linear model to describe this transaction time:
//
//	Transaction time = Latency + (Beats in transaction) / Throughput
//
//	The goal of this core is to help you identify latency and throughput
//	numbers.
//
//	One measure might be to take the total number of clock cycles, from when
//	the core was enabled to when it was disabled, and to divide by the
//	number of beats transmitted.
//
//	(Poor) Throughput = (Total beats transferred) / (total time)
//
//	In a heavily used bus, this might be a good enough measure.  However,
//	this is a poor measure for most systems where the bus is idle most of
//	the time.  Instead, it might be nice to start the measurement early
//	on during some task, and conclude it much later.  In the meantime, the
//	bus might go from idle to busy and back again many times.  For example,
//	you don't want to copy information from the disk drive if you haven't
//	made a request of the controller.  For these reasons, we try to achieve
//	a better measurement.
//
//	Here's the basic approach: we'll look at all of the clocks associated
//	with any particular type of transaction, and lump them into a couple
//	of categories: latency limiting clocks and throughput limiting clocks.
//	We'll then divide the latency limiting clocks by the number of bursts
//	that have taken place, and divide the total number of beats by the
//	time taken to transmit them.
//
//		Latency = (latency measures) / (bursts)
//		Throughput = (beats) / (transmission duration, inc. beats)
//
//	In general, we'll define the transmission duration as the time from the
//	first clock cycle that RVALID (or WVALID) is raised until the final
//	cycle when RVALID && RREADY && RLAST (or WVALID && WREADY && WLAST).
//	Unless we know otherwise, all clock cycles between these two will
//	be marked as a transmission duration clock cycles.  The exception
//	to this rule, however, is the W* channel where one or two W*
//	transactions might take place prior to the first AW* transaction.  In
//	this case, any idle cycles during this time are marked as a latency
//	measure, not a throughput measure of transmission duration.
//
//	Latency measures, on the other hand, are anything that appear to be
//	burst related--such as the time from the request to the first
//	RVALID (or WVALID), or similarly the time from the last WVALID && WLAST
//	until the final BVALID && BREADY.
//
//	These measures are listed in more detail below.
//
//	Certain measures below are marked as *ORTHOGONAL*.  These are perhaps
//	better known as (independent), but I started calling them orthogonal
//	and ... will probably do so for some time.  Orthogonal measures are
//	those that don't overlap.  For example, if you just counted AWVALID
//	&& AWREADY (bursts) and WVALID && WREADY clock cycles (beats), you might
//	get a big overlap between the two and so not know which to count.  Not
//	so with the orthogonal measures.
//
//	Further, at the end of every list of orthogonal measures is a metric
//	that can be used to calculate total cycles used--that way you know
//	how the measures relate.
// }}}
// Registers
// {{{
//	  0: Active time
//		Number of clock periods that the performance monitor has been
//		accumulating data for.
//	  4: Max bursts
//	   Bits 31:24 -- the maximum number of outstanding write bursts at any
//			given time.  A write burst begins with either
//			AWVALID && AWREADY or WVALID && WREADY and ends with
//			BVALID && BREADY.  This will be the maximum of the two.
//	   Bits 23:16 -- the maximum number of outstanding read bursts at any
//			given time.  A read burst begins with ARVALID &&ARREADY,
//			and ends with RVALID && RLAST
//	   Bits 15: 8 -- the maximum write burst size seen, as captured by AWLEN
//	   Bits  7: 0 -- the maximum read burst size seen, as captured by ARLEN
//	  8: Write idle cycles
//		Number of cycles where the write channel is totally idle.
//						*ORTHOGONAL*
//	 12: AWBurst count
//		Number of AWVALID && AWREADY's
//	 16: Write beat count
//		Number of write beats, WVALID && WREADYs
//	 20: AW Byte count
//		Number of bytes written, as recorded by the AW* channel (not the
//		W* channel and WSTRB signals)
//	 24: Write Byte count
//		Number of bytes written, as recorded by the W* channel and the
//		non zero WSTRB's
//	 28: Write slow data
//		Number of cycles where a write has started, that is WVALID
//		and WREADY (but !WLAST) have been seen, but yet WVALID is now
//		low.  These are only counted if a write address request has
//		already been received--otherwise this would be considered
//		a latency measure on the AW* channel.
//						*ORTHOGONAL*
//	 32: wr_stall--Write stalls
//		Counts the number of cycles where WVALID && !WREADY, but
//		only if AWVALID is true or has been true.  This is to
//		distinguish from stalls which may take place before AWVALID,
//		where the slave may be waiting on AWVALID (lag) versus
//		unable to handle the throuhgput.  (Those are counted under
//		wr_early_stall below ...)
//						*ORTHOGONAL*
//	 36: wr_addr_lag--Write address channel lagging
//		Counts the number of cycles where the write data has been
//		present on the channel prior to the write address.  This
//		includes cycles where AWVALID is true or stalled, just not
//		cycles where WVALID is also true--since those have already
//		been counted.
//						*ORTHOGONAL*
//	 40: wr_data_lag--Write data laggging
//		The AWVALID && AWREADY has been received, but no data has
//		yet been received for this write burst and WVALID remains
//		low.  (i.e., no BVALIDs are pending either.)  This is a
//		lag measure since WVALID hasn't shown up (yet) to start sending
//		data.
//						*ORTHOGONAL*
//	 44: wr_awr_early--AWVALID && AWREADY, but only if !WVALID and
//		no AWVALID has yet been received.  This is a lag measure since
//		AWVALID is preceding WVALID.
//						*ORTHOGONAL*
//	 48: wr_early_beat--WVALID && WREADY && !AWVALID, and also prior to
//		any AWVALID.  This value is double counted in the write
//		beat counts, so you will need to subtract the two if you
//		wish to separate them.
//						*Otherwise ORTHOGONAL*
//	 52: wr_addr_stall--AWVALID && !AWREADY, but only if !WVALID and
//		no AWVALID has yet been received.  (This keeps it from being
//		double counted as part of a throughput measure.)
//						*ORTHOGONAL*
//	 56: wr_early_stall--WVALID && !WREADY, but only if this burst has
//		not yet started and no AWVALID has yet been received.  That
//		makes this a lag measure, since the slave is likely waiting
//		for the address before starting to process the burst.
//						*ORTHOGONAL*
//	 60: b_lag_count
//		Counts the number of cycles between the last accepted AWVALID
//		and WVALID && WLAST and its corresponding BVALID.  This is
//		the number of cycles where BVALID could be high in response
//		to any burst, but yet where it isn't.  To avoid interfering
//		with the throughput measure, this excludes any cycles where
//		WVALID is also true.
//						*ORTHOGONAL*
//	 64: b_stall_count
//		Number of cycles where BVALID && !BREADY.  This could be a
//		possible indication of backpressure in the interconnect.
//		This also excludes any cycles where WVALID is also true.
//						*ORTHOGONAL*
//
//	 72: Write Bias
//		Total number of cycles between the first AWVALID and the
//		first WVALID, minus the total number of cycles between the
//		first WVALID and the first AWVALID.  This is a measure of
//		how often AWV clock cycles come before the first WV cycle and
//		by how much.  To make use of this statistic, divide it by the
//		total number of bursts for the average distance between the
//		first AWV and the first WV.  Negative distances are possible
//		if the first WV tends to precede the first AWV.
//	 76: AWR Cycles
//		Number of clock cycles between the first AWVALID of any burst
//		and the last BVALID && BREADY clearing the channel again.
//		This includes any cycles where AWVALID && !AWREADY prior to the
//		first brust being accepted.
//
//	 80: Write cycles
//		Number of clock cycles between the first WVALID of any burst
//		and the last BVALID && BREADY clearing the channel again.
//		This includes the number of cycles where WVALID && !WREADY,
//		even if the channel would be otherwise idle.
//
//	Total write cycles = max(AWR Cycles, Write Cycles)
//		= (wr_addr_lag+wr_data_lag+wr_awr_early+wr_early_beat
//			+ wr_addr_stall + wr_b_lag_count + wr_b_stall_count)
//		    + (wr_slow_data + wr_stall + wr_beats - wr_early_beats)
//
//	Latency = (wr_addr_lag + wr_data_lag + wr_awr_early + wr_early_beat
//			+ wr_addr_stall + wr_b_lag + wr_b_stall) / WR BURSTS
//	Throughput= (wr_beats) /
//			(wr_slow_data + wr_stall + wr_beats - wr_early_beats)
//
//	 84: Read idle cycles
//		Number of clock cycles, while the core is collecting, where
//		nothing is happening on the read channel--ARVALID is low,
//		nothing is outstanding, etc.	*ORTHOGONAL*
//	 88: Max responding bursts
//		This is the maximum number of bursts that have been responding
//		at the same time, as counted by the maximum number of ID's
//		which have seen an RVALID but not RLAST.  It's an estimate of
//		how out of order the channel has become.
//	 92: Read burst count
//		The total number of RVALID && RREADY && RLAST's seen
//	 96: Read beat count
//		The total number of beats requested, as measured by
//		RVALID && RREADY (or equivalently by ARLEN ... but we measure
//		RVALID && RREADY here).		*ORTHOGONAL*
//	100: Read byte count
//		The total number of bytes requested, as measured by ARSIZE
//		and ARLEN.
//	104: AR cycles
//		Total number of cycles where the interface is idle, but yet
//		ARVALID && ARREADY are both true.  Yes, it'll be busy on the
//		next cycle, but we still need to count them.
//						*ORTHOGONAL*
//	108: AR stalls
//		Total number of clock cycles where ARVALID && !ARREADY, but
//		only under the condition that nothing is currently outstanding.
//		If the master refuses to allow a second AR* burst into the
//		pipeline, this should show in the maximum number of outstanding
//		read bursts ever allowed.	*ORTHOGONAL*
//	112: R stalls
//		Total number of clock cycles where RVALID && !RREADY.  This is
//		an indication of a master that has issued more read requests
//		than it can process, and so it is suffering from internal
//		back pressure.			*ORTHOGONAL*
//	116: Lag counter
//		Counts the number of clock cycles where an outstanding read
//		request exists, but for which no data has (yet) been returned.
//						*ORTHOGONAL*
//	120: Slow link
//		Counts the number of clock cycles where RVALID is low, but yet
//		a burst return has already started but not yet been completed.
//						*ORTHOGONAL*
//
//		If we've done this right, then
//
//			active_time == read idle cycles (channel is idle)
//				+ read_beat_count (data is transferred)_
//				+ r stalls	(Master isn't ready)
//				+ lag counter	(No data is ready)
//				+ slow link	(Slave isn't ready))
//				+ rd_ar_stalls	(Slave not ready for AR*)
//				+ rd_ar_cycles	(Slave accepted AR*, o.w. idle)
//
//		We can then measure read throughput as the number of
//		active cycles (active time - read idle counts) divided by the
//		number of bytes (or beats) transferred (depending upon the
//		units you want.
//
//		Lag would be measured by the lag counter divided by the number
//		of read bursts.
//
//	124: Control register
//		Write a 1 to this register to start recording, and a 0 to this
//		register to stop.  Writing a 2 will clear the counters as
//		well.
//
// Performance:
//	Write Throughput = (Wr Beats) / (Wr Beats + WrStalls + WrSlow);
//	Read Throughput = (Rd Beats) / (Rd Beats + R Stalls + RSlow);
//	Read Latency    = (AR Stalls + RdLag) ./ (Rd Bursts)
// }}}
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2020-2021, Gisselquist Technology, LLC
// {{{
//
// This file is part of the WB2AXIP project.
//
// The WB2AXIP project contains free software and gateware, licensed under the
// Apache License, Version 2.0 (the "License").  You may not use this project,
// or this file, except in compliance with the License.  You may obtain a copy
// of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
// License for the specific language governing permissions and limitations
// under the License.
//
////////////////////////////////////////////////////////////////////////////////
// }}}
//
`default_nettype none
//
module	axiperf #(
		// {{{
		//
		// Size of the AXI-lite bus.  These are fixed, since 1) AXI-lite
		// is fixed at a width of 32-bits by Xilinx def'n, and 2) since
		// we only ever have 4 configuration words.
		parameter	C_AXIL_ADDR_WIDTH = 7,
		localparam	C_AXIL_DATA_WIDTH = 32,
		parameter	C_AXI_DATA_WIDTH = 32,
		parameter	C_AXI_ADDR_WIDTH = 32,
		parameter	C_AXI_ID_WIDTH = 4,
		parameter [0:0]	OPT_LOWPOWER = 0,
		parameter	LGCNT = 32
		// }}}
	) (
		// {{{
		input	wire					S_AXI_ACLK,
		input	wire					S_AXI_ARESETN,
		//
		input	wire					S_AXIL_AWVALID,
		output	wire					S_AXIL_AWREADY,
		input	wire	[C_AXIL_ADDR_WIDTH-1:0]		S_AXIL_AWADDR,
		input	wire	[2:0]				S_AXIL_AWPROT,
		//
		input	wire					S_AXIL_WVALID,
		output	wire					S_AXIL_WREADY,
		input	wire	[C_AXIL_DATA_WIDTH-1:0]		S_AXIL_WDATA,
		input	wire	[C_AXIL_DATA_WIDTH/8-1:0]	S_AXIL_WSTRB,
		//
		output	wire					S_AXIL_BVALID,
		input	wire					S_AXIL_BREADY,
		output	wire	[1:0]				S_AXIL_BRESP,
		//
		input	wire					S_AXIL_ARVALID,
		output	wire					S_AXIL_ARREADY,
		input	wire	[C_AXIL_ADDR_WIDTH-1:0]		S_AXIL_ARADDR,
		input	wire	[2:0]				S_AXIL_ARPROT,
		//
		output	wire					S_AXIL_RVALID,
		input	wire					S_AXIL_RREADY,
		output	wire	[C_AXIL_DATA_WIDTH-1:0]		S_AXIL_RDATA,
		output	wire	[1:0]				S_AXIL_RRESP,
		//
		//
		// The AXI Monitor interface
		//
		input	wire				M_AXI_AWVALID,
		input	wire				M_AXI_AWREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_AWID,
		input	wire	[C_AXI_ADDR_WIDTH-1:0]	M_AXI_AWADDR,
		input	wire	[7:0]			M_AXI_AWLEN,
		input	wire	[2:0]			M_AXI_AWSIZE,
		input	wire	[1:0]			M_AXI_AWBURST,
		input	wire				M_AXI_AWLOCK,
		input	wire	[3:0]			M_AXI_AWCACHE,
		input	wire	[2:0]			M_AXI_AWPROT,
		input	wire	[3:0]			M_AXI_AWQOS,
		//
		//
		input	wire				M_AXI_WVALID,
		input	wire				M_AXI_WREADY,
		input	wire	[C_AXI_DATA_WIDTH-1:0]	M_AXI_WDATA,
		input	wire [C_AXI_DATA_WIDTH/8-1:0]	M_AXI_WSTRB,
		input	wire				M_AXI_WLAST,
		//
		//
		input	wire				M_AXI_BVALID,
		input	wire				M_AXI_BREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_BID,
		input	wire	[1:0]			M_AXI_BRESP,
		//
		//
		input	wire				M_AXI_ARVALID,
		input	wire				M_AXI_ARREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_ARID,
		input	wire	[C_AXI_ADDR_WIDTH-1:0]	M_AXI_ARADDR,
		input	wire	[7:0]			M_AXI_ARLEN,
		input	wire	[2:0]			M_AXI_ARSIZE,
		input	wire	[1:0]			M_AXI_ARBURST,
		input	wire				M_AXI_ARLOCK,
		input	wire	[3:0]			M_AXI_ARCACHE,
		input	wire	[2:0]			M_AXI_ARPROT,
		input	wire	[3:0]			M_AXI_ARQOS,
		//
		input	wire				M_AXI_RVALID,
		input	wire				M_AXI_RREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_RID,
		input	wire	[C_AXI_DATA_WIDTH-1:0]	M_AXI_RDATA,
		input	wire				M_AXI_RLAST,
		input	wire	[1:0]			M_AXI_RRESP
		//
		// }}}
	);

	////////////////////////////////////////////////////////////////////////
	//
	// Register/wire signal declarations
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	localparam	ADDRLSB = $clog2(C_AXIL_DATA_WIDTH/8);
	wire	i_reset = !S_AXI_ARESETN;

	// AXI signaling
	// {{{
	wire				axil_write_ready;
	wire	[C_AXIL_ADDR_WIDTH-ADDRLSB-1:0]	awskd_addr;
	//
	wire	[C_AXIL_DATA_WIDTH-1:0]	wskd_data;
	wire [C_AXIL_DATA_WIDTH/8-1:0]	wskd_strb;
	reg				axil_bvalid;
	//
	wire				axil_read_ready;
	wire	[C_AXIL_ADDR_WIDTH-ADDRLSB-1:0]	arskd_addr;
	reg	[C_AXIL_DATA_WIDTH-1:0]	axil_read_data;
	reg				axil_read_valid;

	wire	awskd_valid, wskd_valid;
	wire	arskd_valid;
	// }}}

	reg		idle_bus, triggered, stop_request,
			clear_request, start_request;
	reg	[LGCNT-1:0]	active_time;
	reg	[7:0]	wr_max_burst_size;
	reg	[LGCNT-1:0]	wr_awburst_count, wr_wburst_count, wr_beat_count;
	reg	[LGCNT-1:0]	wr_aw_byte_count, wr_w_byte_count;
	reg	[7:0]	wr_aw_outstanding, wr_w_outstanding,
			wr_aw_max_outstanding, wr_w_max_outstanding,
			wr_max_outstanding, wr_now_outstanding;
	reg		wr_aw_zero_outstanding, wr_w_zero_outstanding,
			wr_in_progress;
	reg	[LGCNT-1:0]	wr_idle_cycles,
			wr_b_lag_count, wr_b_stall_count,
			wr_slow_data, wr_stall, wr_early_beat, // wr_beat,
			wr_addr_lag, wr_data_lag, wr_awr_early,
			wr_bias, wr_addr_stall, wr_early_stall;
	reg[C_AXI_DATA_WIDTH/8:0]	wstrb_count;

	reg [LGCNT-1:0]	rd_idle_cycles, rd_lag_counter, rd_slow_link,
			rd_burst_count, rd_byte_count, rd_beat_count,
			rd_ar_stalls, rd_r_stalls, rd_ar_cycles;
	reg	[7:0]	rd_outstanding_bursts, rd_max_burst_size,
			rd_max_outstanding_bursts;
	reg [7:0]	rd_outstanding_bursts_id [0:(1<<C_AXI_ID_WIDTH)-1];
	reg [(1<<C_AXI_ID_WIDTH)-1:0]	rd_nonzero_outstanding_id,
			rd_bursts_in_flight;
	reg [C_AXI_ID_WIDTH:0]	rd_total_in_flight, rd_responding,
			rd_max_responding_bursts;
	reg		rd_responding_d;

	reg [LGCNT-1:0]	wr_cycles, awr_cycles;
	reg	last_awr_stall, last_wr_stall;

	integer		ik;
	genvar		gk;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI-lite signaling
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	//
	// Write signaling
	//
	// {{{
	skidbuffer #(.OPT_OUTREG(0),
			.OPT_LOWPOWER(OPT_LOWPOWER),
			.DW(C_AXIL_ADDR_WIDTH-ADDRLSB))
	axilawskid(//
		.i_clk(S_AXI_ACLK), .i_reset(i_reset),
		.i_valid(S_AXIL_AWVALID), .o_ready(S_AXIL_AWREADY),
		.i_data(S_AXIL_AWADDR[C_AXIL_ADDR_WIDTH-1:ADDRLSB]),
		.o_valid(awskd_valid), .i_ready(axil_write_ready),
		.o_data(awskd_addr));

	skidbuffer #(.OPT_OUTREG(0),
			.OPT_LOWPOWER(OPT_LOWPOWER),
			.DW(C_AXIL_DATA_WIDTH+C_AXIL_DATA_WIDTH/8))
	axilwskid(//
		.i_clk(S_AXI_ACLK), .i_reset(i_reset),
		.i_valid(S_AXIL_WVALID), .o_ready(S_AXIL_WREADY),
		.i_data({ S_AXIL_WDATA, S_AXIL_WSTRB }),
		.o_valid(wskd_valid), .i_ready(axil_write_ready),
		.o_data({ wskd_data, wskd_strb }));

	assign	axil_write_ready = awskd_valid && wskd_valid
			&& (!S_AXIL_BVALID || S_AXIL_BREADY);

	initial	axil_bvalid = 0;
	always @(posedge S_AXI_ACLK)
	if (i_reset)
		axil_bvalid <= 0;
	else if (axil_write_ready)
		axil_bvalid <= 1;
	else if (S_AXIL_BREADY)
		axil_bvalid <= 0;

	assign	S_AXIL_BVALID = axil_bvalid;
	assign	S_AXIL_BRESP = 2'b00;
	// }}}

	//
	// Read signaling
	//
	// {{{
	skidbuffer #(.OPT_OUTREG(0),
			.OPT_LOWPOWER(OPT_LOWPOWER),
			.DW(C_AXIL_ADDR_WIDTH-ADDRLSB))
	axilarskid(//
		.i_clk(S_AXI_ACLK), .i_reset(i_reset),
		.i_valid(S_AXIL_ARVALID), .o_ready(S_AXIL_ARREADY),
		.i_data(S_AXIL_ARADDR[C_AXIL_ADDR_WIDTH-1:ADDRLSB]),
		.o_valid(arskd_valid), .i_ready(axil_read_ready),
		.o_data(arskd_addr));

	assign	axil_read_ready = arskd_valid
			&& (!axil_read_valid || S_AXIL_RREADY);

	initial	axil_read_valid = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (i_reset)
		axil_read_valid <= 1'b0;
	else if (axil_read_ready)
		axil_read_valid <= 1'b1;
	else if (S_AXIL_RREADY)
		axil_read_valid <= 1'b0;

	assign	S_AXIL_RVALID = axil_read_valid;
	assign	S_AXIL_RDATA  = axil_read_data;
	assign	S_AXIL_RRESP = 2'b00;
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI-lite register logic
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	always @(posedge S_AXI_ACLK)
	begin
		clear_request <= 1'b0;
		if (!clear_request && idle_bus)
		begin
			start_request <= 0;
			stop_request <= 0;
		end

		if (axil_write_ready)
		begin
			case(awskd_addr)
			5'h1f:	if (wskd_strb[0]) begin
				// Start, stop, clear, reset
				//
				clear_request <=  wskd_data[1] && !wskd_data[0];
				stop_request  <= !wskd_data[0];
				start_request <=  wskd_data[0] && (!stop_request);
				end
			default: begin end
			endcase
		end

		if (!S_AXI_ARESETN)
		begin
			clear_request <= 1'b0;
			stop_request <= 1'b0;
			start_request <= 1'b0;
		end
	end

	initial	axil_read_data = 0;
	always @(posedge S_AXI_ACLK)
	if (OPT_LOWPOWER && !S_AXI_ARESETN)
		axil_read_data <= 0;
	else if (!S_AXIL_RVALID || S_AXIL_RREADY)
	begin
		axil_read_data <= 0;
		case(arskd_addr)
		5'h00: axil_read_data[LGCNT-1:0] <= active_time;
		5'h01: axil_read_data <= { wr_max_outstanding,
					rd_max_outstanding_bursts,
					wr_max_burst_size,
					rd_max_burst_size };
		5'h02: axil_read_data[LGCNT-1:0] <= wr_idle_cycles;
		5'h03: axil_read_data[LGCNT-1:0] <= wr_awburst_count;
		5'h04: axil_read_data[LGCNT-1:0] <= wr_beat_count;
		5'h05: axil_read_data[LGCNT-1:0] <= wr_aw_byte_count;
		5'h06: axil_read_data[LGCNT-1:0] <= wr_w_byte_count;
		//
		5'h07: axil_read_data[LGCNT-1:0] <= wr_slow_data;
		5'h08: axil_read_data[LGCNT-1:0] <= wr_stall;
		5'h09: axil_read_data[LGCNT-1:0] <= wr_addr_lag;
		5'h0a: axil_read_data[LGCNT-1:0] <= wr_data_lag;
		5'h0b: axil_read_data[LGCNT-1:0] <= wr_awr_early;
		5'h0c: axil_read_data[LGCNT-1:0] <= wr_early_beat;
		5'h0d: axil_read_data[LGCNT-1:0] <= wr_addr_stall;
		5'h0e: axil_read_data[LGCNT-1:0] <= wr_early_stall;
		5'h0f: axil_read_data[LGCNT-1:0] <= wr_b_lag_count;
		5'h10: axil_read_data[LGCNT-1:0] <= wr_b_stall_count;
		// 5'h10:
		//
		5'h12: axil_read_data[LGCNT-1:0] <= wr_bias;
		5'h13: axil_read_data[LGCNT-1:0] <= awr_cycles;
		5'h14: axil_read_data[LGCNT-1:0] <= wr_cycles;
		//
		5'h15: axil_read_data[LGCNT-1:0] <= rd_idle_cycles;
		5'h16: axil_read_data	<= {
				{(C_AXIL_DATA_WIDTH-C_AXI_ID_WIDTH-1){1'b0}},
				rd_max_responding_bursts };
		5'h17: axil_read_data[LGCNT-1:0] <= rd_burst_count;
		5'h18: axil_read_data[LGCNT-1:0] <= rd_beat_count;
		5'h19: axil_read_data[LGCNT-1:0] <= rd_byte_count;
		5'h1a: axil_read_data[LGCNT-1:0] <= rd_ar_cycles;
		5'h1b: axil_read_data[LGCNT-1:0] <= rd_ar_stalls;
		5'h1c: axil_read_data[LGCNT-1:0] <= rd_r_stalls;
		5'h1d: axil_read_data[LGCNT-1:0] <= rd_lag_counter;
		5'h1e: axil_read_data[LGCNT-1:0] <= rd_slow_link;
		5'h1f: axil_read_data <= {
				// pending_idle,
				// pending_first_burst,
				// cleared,
				28'h0, 1'b0,
				triggered,
				clear_request,
				start_request
				};
		default: begin end
		endcase

		if (OPT_LOWPOWER && !axil_read_ready)
			axil_read_data <= 0;
	end

	function [C_AXI_DATA_WIDTH-1:0]	apply_wstrb;
		input	[C_AXI_DATA_WIDTH-1:0]		prior_data;
		input	[C_AXI_DATA_WIDTH-1:0]		new_data;
		input	[C_AXI_DATA_WIDTH/8-1:0]	wstrb;

		integer	k;
		for(k=0; k<C_AXI_DATA_WIDTH/8; k=k+1)
		begin
			apply_wstrb[k*8 +: 8]
				= wstrb[k] ? new_data[k*8 +: 8] : prior_data[k*8 +: 8];
		end
	endfunction
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI performance counters
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// triggered
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		triggered <= 0;
	else if (start_request)
	begin
		if (idle_bus)
			triggered <= 1'b1;
	end else if (stop_request && idle_bus)
		triggered <= 0;
	// }}}

	// active_time : count number of cycles while triggered
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		active_time <= 0;
	else if (triggered)
		active_time <= active_time + 1;
	// }}}

	// idle_bus : Can we start or stop our couters?  Can't if not idle
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		idle_bus <= 1;
	else if (M_AXI_AWVALID || M_AXI_WVALID || M_AXI_ARVALID)
		idle_bus <= 0;
	else if ((wr_aw_outstanding
			==((M_AXI_BVALID && M_AXI_BREADY) ? 1:0))
		&& (wr_w_outstanding == ((M_AXI_BVALID && M_AXI_BREADY) ? 1:0))
		&& (rd_outstanding_bursts
			==((M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST)? 1:0)))
		idle_bus <= 1;
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Write statistics
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// wr_max_burst_size: max of all AWLEN values
	// {{{
	initial	wr_max_burst_size = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_max_burst_size <= 0;
	else if (triggered)
	begin
		if (M_AXI_AWVALID && M_AXI_AWLEN > wr_max_burst_size)
			wr_max_burst_size <= M_AXI_AWLEN;
	end
	// }}}

	// wr_awburst_count -- count AWVALID && AWREADY
	// {{{
	initial	wr_awburst_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_awburst_count <= 0;
	else if (triggered && M_AXI_AWVALID && M_AXI_AWREADY)
		wr_awburst_count <= wr_awburst_count + 1;
	// }}}

	// wr_wburst_count -- count of WVALID && WLAST && WREADY
	// {{{
	initial	wr_wburst_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_wburst_count <= 0;
	else if (triggered && M_AXI_WVALID && M_AXI_WREADY && M_AXI_WLAST)
		wr_wburst_count <= wr_wburst_count + 1;
	// }}}

	// wr_beat_count -- count of WVALID && WREADY
	// {{{
	initial	wr_beat_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_beat_count <= 0;
	else if (triggered && M_AXI_WVALID && M_AXI_WREADY)
		wr_beat_count <= wr_beat_count + 1;
	// }}}

	// wstrb_count -- combinatorial, current active strobe count
	// {{{
	always @(*)
	begin
		wstrb_count = 0;
		for(ik=0; ik<C_AXI_DATA_WIDTH/8; ik=ik+1)
		if (M_AXI_WSTRB[ik])
			wstrb_count = wstrb_count + 1;
	end
	// }}}

	// wr_aw_byte_count : count of (AWLEN+1)<<AWSIZE
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_aw_byte_count <= 0;
	else if (triggered && M_AXI_AWVALID && M_AXI_AWREADY)
	begin
		wr_aw_byte_count <= wr_aw_byte_count
			+ (({ 24'b0, M_AXI_AWLEN}+32'h1) << M_AXI_AWSIZE);
	end
	// }}}

	// wr_w_byte_count : Count of active WSTRBs
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_w_byte_count <= 0;
	else if (triggered && M_AXI_WVALID && M_AXI_WREADY)
	begin
		wr_w_byte_count <= wr_w_byte_count
			+ { {(32-C_AXI_DATA_WIDTH/8-1){1'b0}}, wstrb_count };
	end
	// }}}

	// wr_aw_outstanding, wr_aw_zero_outstanding: AWV && AWR - BV && BR
	// {{{
	initial	wr_aw_outstanding = 0;
	initial	wr_aw_zero_outstanding = 1;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
	begin
		wr_aw_outstanding <= 0;
		wr_aw_zero_outstanding <= 1;
	end else case ({ M_AXI_AWVALID && M_AXI_AWREADY,
				M_AXI_BVALID && M_AXI_BREADY })
	2'b10: begin
		wr_aw_outstanding <= wr_aw_outstanding + 1;
		wr_aw_zero_outstanding <= 0;
		end
	2'b01: begin
		wr_aw_outstanding <= wr_aw_outstanding - 1;
		wr_aw_zero_outstanding <= (wr_aw_outstanding <= 1);
		end
	default: begin end
	endcase
	// }}}

	// wr_aw_max_outstanding : max of wr_aw_outstanding
	// {{{
	initial	wr_aw_max_outstanding = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_aw_max_outstanding <= 0;
	else if (triggered && (wr_aw_max_outstanding < wr_aw_outstanding))
		wr_aw_max_outstanding <= wr_aw_outstanding;
	// }}}

	// wr_w_outstanding, wr_w_zero_outstanding: WV & WR & WL - BV & BR
	// {{{
	initial	wr_w_outstanding = 0;
	initial	wr_w_zero_outstanding = 1;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
	begin
		wr_w_outstanding <= 0;
		wr_w_zero_outstanding <= 1;
	end else case ({ M_AXI_WVALID && M_AXI_WREADY && M_AXI_WLAST,
				M_AXI_BVALID && M_AXI_BREADY })
	2'b10: begin
		wr_w_outstanding <= wr_w_outstanding + 1;
		wr_w_zero_outstanding <= 0;
		end
	2'b01: begin
		wr_w_outstanding <= wr_w_outstanding - 1;
		wr_w_zero_outstanding <= (wr_w_outstanding <= 1);
		end
	default: begin end
	endcase
	// }}}

	// wr_w_max_outstanding: max of wr_w_outstanding + wr_in_progress
	// {{{
	initial	wr_w_max_outstanding = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_w_max_outstanding <= 0;
	else if (triggered)
	begin
		if (wr_w_outstanding + (wr_in_progress ? 1:0)
					> wr_max_outstanding)
			wr_w_max_outstanding <= wr_w_outstanding
						+ (wr_in_progress ? 1:0);
	end
	// }}}

	// wr_now_outs*, wr_max_outs*: max of wr_w_outs* and wr_aw_outs*
	// {{{
	always @(*)
	begin
		wr_now_outstanding = 0;
		wr_now_outstanding = wr_w_max_outstanding;
		if (wr_aw_max_outstanding > wr_now_outstanding)
			wr_now_outstanding = wr_aw_max_outstanding;
	end

	initial	wr_max_outstanding = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_max_outstanding <= 0;
	else if (triggered)
	begin
		if (wr_now_outstanding > wr_max_outstanding)
			wr_max_outstanding <= wr_now_outstanding;
	end
	// }}}

	// wr_in_progress: Flag, true between WVALID and WV && WR && WLAST
	// {{{
	initial	wr_in_progress = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		wr_in_progress <= 0;
	else case ({ M_AXI_WVALID && (!M_AXI_WREADY || !M_AXI_WLAST),
				M_AXI_WVALID && M_AXI_WREADY && M_AXI_WLAST })
	2'b10: wr_in_progress <= 1;
	2'b01: wr_in_progress <= 0;
	default: begin end
	endcase
	// }}}

	// Orthogonal write statistics
	// {{{
	// Here's where we capture our orthogonal measures for the write
	// channel.  It's important that, for all of these counters, only
	// one of them ever counts a given burst.  Hence, our criteria are
	// binned and orthogonalized below.
	//
	//	AW_O W_O WIP AWV AWR WV WR BV BR
	//	0    0	 0   0       0		IDLE-CYCLE
	//	1     	 1           0		SLOW-DATA
	//	1     	             1	0	Write stall (#1)
	//	0     	 1           1	0	Write stall (#2)
	//	      	             1  1	W-BEAT   (Counted elsewhere)
	//
	//	0    0   0   1       0		W-DATA-LAG (#1)
	//	1    0   0           0		W-DATA-LAG (#2)
	//	0    1   0           0		WR Early (AWR after WLAST)
	//	0        1           0		Write data before AWR
	//
	//
	//
	//	0     	     0       1	1	Early write beat (special)
	//	      	     1   1       	AW-BURST (Counted elsewhere)
	//
	// (DRAFT) Single channel AWR orthogonal
	// {{{
	//	AWR bursts (got that)
	//	AWR Cycles = (AWR latency) + (WR Beats) / (Throughput)
	//
	//	AWR bias = (counts where W follows AW)
	//		- (counts where AW follows W)
	//	If (AWR bias > 0), then
	//		Write lag = (BLAG + AWR bias) / AWR beats
	//	Else if (AWR bias < 0) (WData before AWVALID), then
	//		Write lag = (BLAG - AWR bias) / AWR beats
	//		Write throughput = (WR BEATS + WR STALL + WR SLOW
	//					+ AWR bias) / WR Beats
	// }}}
	// Skip the boring stuffs (if using VIM folding)
	// {{{
	initial	wr_data_lag      = 0;
	initial	wr_idle_cycles   = 0;
	initial	wr_b_lag_count   = 0;
	initial	wr_b_stall_count = 0;
	initial	wr_slow_data     = 0;
	initial	wr_stall         = 0;
	initial	wr_early_beat    = 0;
	// initial	wr_aw_burst      = 0;
	initial	wr_addr_stall    = 0;
	initial	wr_addr_lag      = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
	begin
		wr_data_lag      <= 0;
		wr_idle_cycles   <= 0;
		wr_b_lag_count   <= 0;
		wr_b_stall_count <= 0;
		wr_slow_data     <= 0;
		wr_stall         <= 0;
		wr_data_lag      <= 0;
		wr_addr_stall    <= 0;
		wr_addr_lag      <= 0;
		wr_early_stall   <= 0;
	end else if (triggered)
	// }}}
	casez({ !wr_aw_zero_outstanding, !wr_w_zero_outstanding,
		wr_in_progress,
		M_AXI_AWVALID, M_AXI_AWREADY,
		M_AXI_WVALID,  M_AXI_WREADY,
		M_AXI_BVALID,  M_AXI_BREADY })
	9'b0000?0???: wr_idle_cycles   <= wr_idle_cycles   + 1;
	// 9'b11?????11: begin end // BURST count
	//
// Throughput measures
	9'b1?1??0???: wr_slow_data <= wr_slow_data  + 1;
	9'b1????10??: wr_stall     <= wr_stall      + 1;	// Stall #1
	9'b0?1??10??: wr_stall     <= wr_stall      + 1;	// Stall #2
	//
	9'b0??0?11??: wr_early_beat<= wr_early_beat + 1;	// Before AWV
	// 9'b1??0?11??: wr_beat      <= wr_beat       + 1;
	// 9'b???1?11??: wr_beat      <= wr_beat       + 1;
	//
// Lag measures
	9'b000110???: wr_awr_early  <= wr_awr_early + 1;
	9'b000100???: wr_addr_stall <= wr_addr_stall + 1;
	9'b100??0?0?: wr_data_lag   <= wr_data_lag   + 1;
	9'b010??0???: wr_addr_lag   <= wr_addr_lag   + 1;
	9'b0?1??0???: wr_addr_lag   <= wr_addr_lag   + 1;
	9'b0?0??10??: wr_early_stall<= wr_early_stall+ 1;

	9'b110??0?0?: wr_b_lag_count   <= wr_b_lag_count   + 1;
	9'b110??0?10: wr_b_stall_count <= wr_b_stall_count + 1;
	//
	default: begin end
	endcase
	// }}}

	// AWR Cycles: Counting the time while wr_aw_outstanding > 0
	// {{{
	always @(posedge S_AXI_ACLK)
		last_awr_stall <= (M_AXI_AWVALID && !M_AXI_AWREADY);

	initial	awr_cycles = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		awr_cycles <= 0;
	else if (triggered)
	begin
		if (!wr_aw_zero_outstanding || last_awr_stall)
			awr_cycles <= awr_cycles + 1;
	end
	// }}}

	// WR Cycles: Counting the time while wr_w_outstanding > 0
	// {{{
	always @(posedge S_AXI_ACLK)
		last_wr_stall <= (M_AXI_WVALID && !M_AXI_WREADY);

	initial	wr_cycles = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_cycles <= 0;
	else if (triggered)
	begin
		if (!wr_w_zero_outstanding || wr_in_progress || last_wr_stall)
			wr_cycles <= wr_cycles + 1;
	end
	// }}}

	// WR Bias: How far ahead of WVALID does AWVALID show up?
	// {{{
	initial	wr_bias = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		wr_bias <= 0;
	else if (triggered)
	begin
		if ((!wr_aw_zero_outstanding
			|| (M_AXI_AWVALID && (!M_AXI_AWREADY
					|| (!M_AXI_WVALID || !M_AXI_WREADY))))
			&& (wr_w_zero_outstanding && !wr_in_progress))
			wr_bias <= wr_bias + 1;
		else if ((wr_aw_zero_outstanding
				&& (!M_AXI_AWVALID || !M_AXI_ARREADY))
			&& ((M_AXI_WVALID && (!M_AXI_AWVALID
					|| (M_AXI_WREADY && !M_AXI_AWREADY)))
				|| !wr_w_zero_outstanding || wr_in_progress))
			wr_bias <= wr_bias - 1;
	end
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Read statistics
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// rd_max_burst_size = max(ARLEN)
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_max_burst_size <= 0;
	else if (triggered)
	begin
		if (M_AXI_ARVALID && M_AXI_ARLEN > rd_max_burst_size)
			rd_max_burst_size <= M_AXI_ARLEN;
	end
	// }}}

	// rd_burst_count : Count of RVALID && RREADY && RLAST
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_burst_count <= 0;
	else if (triggered && M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST)
		rd_burst_count <= rd_burst_count + 1;
	// }}}

	// rd_byte_count : Count of (ARLEN+1) << ARSIZE)
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_byte_count <= 0;
	else if (triggered && (M_AXI_ARVALID && M_AXI_ARREADY))
		rd_byte_count <= rd_byte_count
			+ (({ 24'h0, M_AXI_ARLEN} + 32'h1)<< M_AXI_ARSIZE);
	// }}}

	// rd_beat_count : Count of RVALID && RREADY
	// {{{
	initial	rd_beat_count = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_beat_count <= 0;
	else if (triggered && (M_AXI_RVALID && M_AXI_RREADY))
		rd_beat_count <= rd_beat_count+ 1;
	// }}}

	// rd_outstanding_bursts : internal counter, ARV && ARR - RV && RR && RL
	// {{{
	initial	rd_outstanding_bursts = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		rd_outstanding_bursts <= 0;
	else case ({ M_AXI_ARVALID && M_AXI_ARREADY,
				M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST})
	2'b10: rd_outstanding_bursts <= rd_outstanding_bursts + 1;
	2'b01: rd_outstanding_bursts <= rd_outstanding_bursts - 1;
	default: begin end
	endcase
	// }}}

	generate for(gk=0; gk < (1<<C_AXI_ID_WIDTH); gk=gk+1)
	begin : PER_ID_READ_STATISTICS

		// rd_outstanding_bursts_id[gk], rd_nonzero_outstanding_id[gk]
		// {{{
		initial	rd_outstanding_bursts_id[gk]  = 0;
		initial	rd_nonzero_outstanding_id[gk] = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			rd_outstanding_bursts_id[gk]  <= 0;
			rd_nonzero_outstanding_id[gk] <= 0;
		end else case(
			{ M_AXI_ARVALID && M_AXI_ARREADY && (M_AXI_ARID == gk),
				M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST
					&& (M_AXI_RID == gk) })
		2'b10: begin
			rd_outstanding_bursts_id[gk]
					<= rd_outstanding_bursts_id[gk] + 1;
			rd_nonzero_outstanding_id[gk] <= 1'b1;
			end
		2'b01: begin
			rd_outstanding_bursts_id[gk]
					<= rd_outstanding_bursts_id[gk] - 1;
			rd_nonzero_outstanding_id[gk]
					<= (rd_outstanding_bursts_id[gk] > 1);
			end
		default: begin end
		endcase
		// }}}

		// rd_bursts_in_flight : Are bursts in flight for this ID?
		// {{{
		initial	rd_bursts_in_flight = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
			rd_bursts_in_flight[gk] <= 0;
		else case({ M_AXI_RVALID && (M_AXI_RID == gk),
				M_AXI_RREADY && M_AXI_RLAST })
		2'b10: rd_bursts_in_flight[gk] <= 1'b1;
		2'b11: rd_bursts_in_flight[gk] <= 1'b0;
		default: begin end
		endcase
		// }}}

	end endgenerate

	// rd_responding : How many ID's have bursts in flight at any time?
	// {{{
	always @(*)
	begin
		rd_total_in_flight = 0;
		for(ik=0; ik<(1<<C_AXI_ID_WIDTH); ik=ik+1)
		if (rd_bursts_in_flight[ik])
			rd_total_in_flight = rd_total_in_flight + 1;
	end

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
	begin
		rd_responding <= 0;
		rd_responding_d <= 0;
	end else if (triggered)
	begin
		rd_responding <= rd_total_in_flight;
		rd_responding_d <= 1;
	end
	// }}}

	// rd_max_responding_bursts : Max(bursts outstanding at any time)
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_max_responding_bursts <= 0;
	else if (rd_responding_d)
	begin
		if (rd_responding > rd_max_responding_bursts)
			rd_max_responding_bursts <= rd_responding;
	end
	// }}}

	// rd_max_outstanding_bursts :
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_max_outstanding_bursts <= 0;
	else if (triggered)
	begin
		if (rd_outstanding_bursts > rd_max_outstanding_bursts)
			rd_max_outstanding_bursts <= rd_outstanding_bursts;
	end
	// }}}

	// rd_r_stalls : Count of RVALID && !RREADY
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
		rd_r_stalls <= 0;
	else if (triggered && M_AXI_RVALID && !M_AXI_RREADY)
		rd_r_stalls <= rd_r_stalls + 1;
	// }}}

	//
	// Orthogonal read statistics
	// {{{
	// {{{
	initial	rd_idle_cycles = 0;
	initial	rd_lag_counter = 0;
	initial	rd_slow_link   = 0;
	initial	rd_ar_stalls   = 0;
	initial	rd_ar_cycles   = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || clear_request)
	begin
		rd_idle_cycles <= 0;
		rd_lag_counter <= 0;
		rd_slow_link   <= 0;
		rd_ar_stalls   <= 0;
		rd_ar_cycles   <= 0;
	end else if (triggered)
	begin
		// }}}
		if (!M_AXI_RVALID)
		begin
			if (rd_bursts_in_flight != 0)
				rd_slow_link <= rd_slow_link + 1;
			else if (rd_nonzero_outstanding_id != 0)
				rd_lag_counter <= rd_lag_counter + 1;
			else if (!M_AXI_ARVALID)
				rd_idle_cycles <= rd_idle_cycles + 1;
			else if (M_AXI_ARVALID && !M_AXI_ARREADY)
				rd_ar_stalls <= rd_ar_stalls + 1;
			else // if M_AXI_ARVLD && M_AXI_ARRDY && otherwise idle
				rd_ar_cycles <= rd_ar_cycles + 1;
		end // else if (M_AXI_RREADDY) rd_beat_count <= rd_beat_count+1;
	end
	// }}}
	// }}}
	// }}}

	// Make Verilator happy
	// {{{
	// Verilator lint_off UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, S_AXIL_AWPROT, S_AXIL_ARPROT,
			S_AXIL_ARADDR[ADDRLSB-1:0],
			S_AXIL_AWADDR[ADDRLSB-1:0],
			wskd_data, wskd_strb,
			M_AXI_AWBURST, M_AXI_AWLOCK, M_AXI_AWCACHE, M_AXI_AWQOS,
			M_AXI_AWID, M_AXI_AWADDR, M_AXI_ARADDR,
			M_AXI_AWPROT, M_AXI_ARPROT,
			M_AXI_BID, M_AXI_BRESP,
			M_AXI_ARBURST, M_AXI_ARLOCK, M_AXI_ARCACHE, M_AXI_ARQOS,
			M_AXI_WDATA, M_AXI_RDATA,
			M_AXI_RRESP
			};
	// Verilator lint_on  UNUSED
	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal properties used in verfiying this core
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	reg	f_past_valid;
	initial	f_past_valid = 0;
	always @(posedge S_AXI_ACLK)
		f_past_valid <= 1;

	////////////////////////////////////////////////////////////////////////
	//
	// The AXI-lite control interface
	//
	////////////////////////////////////////////////////////////////////////
	//
	// {{{
	localparam	F_AXIL_LGDEPTH = 4;
	wire	[F_AXIL_LGDEPTH-1:0]	faxil_rd_outstanding,
					faxil_wr_outstanding,
					faxil_awr_outstanding;

	faxil_slave #(
		// {{{
		.C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH),
		.C_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH),
		.F_LGDEPTH(F_AXIL_LGDEPTH),
		.F_AXI_MAXWAIT(2),
		.F_AXI_MAXDELAY(2),
		.F_AXI_MAXRSTALL(3),
		.F_OPT_COVER_BURST(4)
		// }}}
	) faxil(
		// {{{
		.i_clk(S_AXI_ACLK), .i_axi_reset_n(S_AXI_ARESETN),
		//
		.i_axi_awvalid(S_AXIL_AWVALID),
		.i_axi_awready(S_AXIL_AWREADY),
		.i_axi_awaddr( S_AXIL_AWADDR),
		.i_axi_awprot( S_AXIL_AWPROT),
		//
		.i_axi_wvalid(S_AXIL_WVALID),
		.i_axi_wready(S_AXIL_WREADY),
		.i_axi_wdata( S_AXIL_WDATA),
		.i_axi_wstrb( S_AXIL_WSTRB),
		//
		.i_axi_bvalid(S_AXIL_BVALID),
		.i_axi_bready(S_AXIL_BREADY),
		.i_axi_bresp( S_AXIL_BRESP),
		//
		.i_axi_arvalid(S_AXIL_ARVALID),
		.i_axi_arready(S_AXIL_ARREADY),
		.i_axi_araddr( S_AXIL_ARADDR),
		.i_axi_arprot( S_AXIL_ARPROT),
		//
		.i_axi_rvalid(S_AXIL_RVALID),
		.i_axi_rready(S_AXIL_RREADY),
		.i_axi_rdata( S_AXIL_RDATA),
		.i_axi_rresp( S_AXIL_RRESP),
		//
		.f_axi_rd_outstanding(faxil_rd_outstanding),
		.f_axi_wr_outstanding(faxil_wr_outstanding),
		.f_axi_awr_outstanding(faxil_awr_outstanding)
		// }}}
		);

	always @(*)
	begin
		assert(faxil_awr_outstanding== (S_AXIL_BVALID ? 1:0)
			+(S_AXIL_AWREADY ? 0:1));
		assert(faxil_wr_outstanding == (S_AXIL_BVALID ? 1:0)
			+(S_AXIL_WREADY ? 0:1));

		assert(faxil_rd_outstanding == (S_AXIL_RVALID ? 1:0)
			+(S_AXIL_ARREADY ? 0:1));
	end

	//
	// Check that our low-power only logic works by verifying that anytime
	// S_AXI_RVALID is inactive, then the outgoing data is also zero.
	//
	always @(*)
	if (OPT_LOWPOWER && !S_AXIL_RVALID)
		assert(S_AXIL_RDATA == 0);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Cover checks
	//
	////////////////////////////////////////////////////////////////////////
	//
	// {{{

	// While there are already cover properties in the formal property
	// set above, you'll probably still want to cover something
	// application specific here

	// }}}
	// }}}
`endif
endmodule
