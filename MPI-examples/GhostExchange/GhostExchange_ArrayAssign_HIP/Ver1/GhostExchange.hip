#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <mpi.h>
#include <hip/hip_runtime.h>

#include "malloc2D.h"
#include "timer.h"

__global__ void init_core (double **x, int nhalo, int jsize, int isize, double val)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x -nhalo;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y -nhalo;
    if (tidy < jsize+nhalo && tidx < isize+nhalo) {
        x[tidy][tidx] = val;
    }
}

__global__ void init_core2 (double **x, int jmax, int jspan, int jbegin, int jend, int imax, int ispan, int ibegin, int iend, int rank)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x + imax/2 - ispan;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y + jmax/2 - jspan;
    if (tidy < jmax/2 + jspan && tidx < imax/2 + ispan) {
        if (tidy >= jbegin && tidy < jend && tidx >= ibegin && tidx < iend) {
           x[tidy-jbegin][tidx-ibegin] = 400.0 + 0.1 * (double)(rank + tidy);
        }
    }
}

__global__ void blur (double **x, double **xnew, int jsize, int isize)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y;
    if (tidy < jsize && tidx < isize) {
        xnew[tidy][tidx] = ( x[tidy][tidx] + x[tidy][tidx-1] + x[tidy][tidx+1] + x[tidy-1][tidx] + x[tidy+1][tidx] )/5.0;
    }
}

__global__ void enforce_bcs_left (double **x, int nhalo, int jsize)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x - nhalo;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y;
    if (tidy < jsize && tidx < 0) {
        x[tidy][tidx] = x[tidy][0];
    }
}

__global__ void enforce_bcs_rght (double **x, int nhalo, int jsize, int isize)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y;
    if (tidy < jsize  && tidx < nhalo) {
        x[tidy][isize+tidx] = x[tidy][isize-1];
    }
}

__global__ void enforce_bcs_bot (double **x, int nhalo, int isize)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x - nhalo;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y - nhalo;
    if (tidy < 0 && tidx < isize + nhalo) {
        x[tidy][tidx] = x[0][tidx];
    }
}

__global__ void enforce_bcs_top (double **x, int nhalo, int jsize, int isize)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x - nhalo;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y;
    if (tidy < nhalo && tidx < isize + nhalo) {
        x[jsize+tidy][tidx] = x[jsize-1][tidx];
    }
}

__global__ void ghost_left_send (double *xbuf_left_send, double **x, int jlow, int jhgh, int nhalo, int bufcount)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y + jlow;
    int offset = (tidy - jlow) * nhalo + tidx;
    if (tidy < jhgh && tidx < nhalo && offset < bufcount) {
        xbuf_left_send[offset] = x[tidy][tidx];
    }
}

__global__ void ghost_rght_send (double *xbuf_rght_send, double **x, int jlow, int jhgh, int isize, int nhalo, int bufcount)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y + jlow;
    int offset = (tidy - jlow) * nhalo + tidx;
    if (tidy < jhgh && tidx < nhalo && offset < bufcount) {
        xbuf_rght_send[offset] = x[tidy][isize - nhalo + tidx];
    }
}

__global__ void ghost_rght_recv (double *xbuf_rght_recv, double **x, int jlow, int jhgh, int isize, int nhalo, int bufcount)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y + jlow;
    int offset = (tidy - jlow) * nhalo + tidx;
    if (tidy < jhgh && tidx < nhalo && offset < bufcount) {
        x[tidy][isize + tidx] = xbuf_rght_recv[offset];
    }
}

__global__ void ghost_left_recv (double *xbuf_left_recv, double **x, int jlow, int jhgh, int nhalo, int bufcount)
{
    int tidx = threadIdx.x + blockIdx.x * blockDim.x;
    int tidy = threadIdx.y + blockIdx.y * blockDim.y + jlow;
    int offset = (tidy - jlow) * nhalo + tidx;
    if (tidy < jhgh && tidx < nhalo && offset < bufcount) {
        x[tidy][tidx - nhalo] = xbuf_left_recv[offset];
    }
}

// ---------------------------------------------------------------------------------
// hipErrorCheck() and print_affinity_info() code adapted from ORNL's hello_jobstep 
// application: https://code.ornl.gov/olcf/hello_jobstep
// ---------------------------------------------------------------------------------
// Macro for checking errors in HIP API calls
#define hipErrorCheck(call)                                                                 \
do{                                                                                         \
    hipError_t hipErr = call;                                                               \
    if(hipSuccess != hipErr){                                                               \
        printf("HIP Error - %s:%d: '%s'\n", __FILE__, __LINE__, hipGetErrorString(hipErr)); \
        exit(0);                                                                            \
    }                                                                                       \
}while(0)

void print_affinity_info (int rank)
{
    // If ROCR_VISIBLE_DEVICES is set, capture visible GPUs
    const char* gpu_id_list;
    const char* rocr_visible_devices = getenv("ROCR_VISIBLE_DEVICES");
    if(rocr_visible_devices == NULL){
        gpu_id_list = "N/A";
    }
    else{
        gpu_id_list = rocr_visible_devices;
    }

    // Find how many GPUs HIP runtime says are available
    int num_devices = 0;
    hipErrorCheck( hipGetDeviceCount(&num_devices) );

    int hwthread;
    int thread_id = 0;
    if(num_devices == 0){
        hwthread = sched_getcpu();
        printf("MPI %03d - HWT %03d\n",
                    rank, hwthread);
    }
    else{

        std::string rt_gpu_id_list = "";

        // Loop over the GPUs available to each MPI rank
        for(int i=0; i<num_devices; i++){

            hipErrorCheck( hipSetDevice(i) );

            // Concatenate per-MPIrank GPU info into strings for print
            if(i > 0) rt_gpu_id_list.append(",");
            rt_gpu_id_list.append(std::to_string(i));
        }
        hwthread = sched_getcpu();

        printf("MPI %03d - HWT %03d - RT_GPU_ID %s - GPU_ID %s\n",
                    rank, hwthread, rt_gpu_id_list.c_str(), gpu_id_list);
    }
}

#define SWAP_PTR(xnew,xold,xtmp) (xtmp=xnew, xnew=xold, xold=xtmp)
void parse_input_args(int argc, char **argv, int &jmax, int &imax, int &nprocy, int &nprocx, int &nhalo, int &corners, int &maxIter, int &do_timing, int &do_print);
void Cartesian_print(double **x, int jmax, int imax, int nhalo, int nprocy, int nprocx);
void boundarycondition_update(double **x, int nhalo, int jsize, int isize, int nleft, int nrght, int nbot, int ntop);
void ghostcell_update(double **x, int nhalo, int corners, int jsize, int isize,
      int nleft, int nrght, int nbot, int ntop, int do_timing);
void haloupdate_test(int nhalo, int corners, int jsize, int isize, int nleft, int nrght, int nbot, int ntop,
      int jmax, int imax, int nprocy, int nprocx, int do_timing, int do_print);

double boundarycondition_time=0.0, ghostcell_time=0.0;

int main(int argc, char *argv[])
{
   MPI_Init(&argc, &argv);

   int rank, nprocs;
   MPI_Comm_rank(MPI_COMM_WORLD, &rank);
   MPI_Comm_size(MPI_COMM_WORLD, &nprocs);
   hipSetDevice(0);

   print_affinity_info (rank);

   int imax = 2000, jmax = 2000;
   int nprocx = 0, nprocy = 0;
   int nhalo = 2, corners = 0;
   int do_timing = 0;
   int do_print = 0;
   int maxIter = 1000;

   parse_input_args(argc, argv, jmax, imax, nprocy, nprocx, nhalo, corners, maxIter, do_timing, do_print);

   if (do_print) {
       if (rank == 0) printf("Parallel run with no threads\n");
   }
 
   struct timespec tstart_stencil, tstart_total;
   double stencil_time=0.0, total_time;
   cpu_timer_start(&tstart_total);

   int xcoord = rank%nprocx;
   int ycoord = rank/nprocx;

   int nleft = (xcoord > 0       ) ? rank - 1      : MPI_PROC_NULL;
   int nrght = (xcoord < nprocx-1) ? rank + 1      : MPI_PROC_NULL;
   int nbot  = (ycoord > 0       ) ? rank - nprocx : MPI_PROC_NULL;
   int ntop  = (ycoord < nprocy-1) ? rank + nprocx : MPI_PROC_NULL;

   int ibegin = imax *(xcoord  )/nprocx;
   int iend   = imax *(xcoord+1)/nprocx;
   int isize  = iend - ibegin;
   int jbegin = jmax *(ycoord  )/nprocy;
   int jend   = jmax *(ycoord+1)/nprocy;
   int jsize  = jend - jbegin;

   /* The halo update both updates the ghost cells and the boundary halo cells. To be precise with terminology,
    * the ghost cells only exist for multi-processor runs with MPI. The boundary halo cells are to set boundary
    * conditions. Halos refer to both the ghost cells and the boundary halo cells.
    */
   haloupdate_test(nhalo, corners, jsize, isize, nleft, nrght, nbot, ntop, jmax, imax, nprocy, nprocx, do_timing, do_print);

   double** xtmp;
   // This offsets the array addressing so that the real part of the array is from 0,0 to jsize,isize
   double** x    = malloc2D(jsize+2*nhalo, isize+2*nhalo, nhalo, nhalo);
   double** xnew = malloc2D(jsize+2*nhalo, isize+2*nhalo, nhalo, nhalo);

   if (! corners) { // need to initialize when not doing corners so there is no uninitialized memory

      dim3 grid((isize+2*nhalo+63)/64, (jsize+2*nhalo+3)/4, 1);
      dim3 block(64, 4, 1);
      init_core <<< grid, block >>> (x, nhalo, jsize, isize, 0.0);
      hipDeviceSynchronize();

   }

   dim3 grid((isize+63)/64, (jsize+3)/4, 1);
   dim3 block(64, 4, 1);
   double val = static_cast<double>(rank) + 5.0;
   init_core <<< grid, block >>> (x, 0, jsize, isize, val);
   hipDeviceSynchronize();

   int ispan=5, jspan=5;
   if (ispan > imax/2) ispan = imax/2;
   if (jspan > jmax/2) jspan = jmax/2;
   
   dim3 grid2((2*ispan+63)/64, (2*jspan+3)/4, 1);
   dim3 block2(64, 4, 1);
   init_core2 <<< grid2, block2 >>> (x, jmax, jspan, jbegin, jend, imax, ispan, ibegin, iend, rank);
   hipDeviceSynchronize();

   boundarycondition_update(x, nhalo, jsize, isize, nleft, nrght, nbot, ntop);
   ghostcell_update(x, nhalo, corners, jsize, isize, nleft, nrght, nbot, ntop, do_timing);

   if (do_print == 1) {
      if (rank == 0) printf("Initial State \n");
      Cartesian_print(x, jmax, imax, nhalo, nprocy, nprocx);
   }

   for (int iter = 0; iter < maxIter; iter++){
      cpu_timer_start(&tstart_stencil);

      blur <<< grid, block >>> (x, xnew, jsize, isize);
      hipDeviceSynchronize();

      SWAP_PTR(xnew, x, xtmp);

      stencil_time += cpu_timer_stop(tstart_stencil);

      boundarycondition_update(x, nhalo, jsize, isize, nleft, nrght, nbot, ntop);
      ghostcell_update(x, nhalo, corners, jsize, isize, nleft, nrght, nbot, ntop, do_timing);

      if (do_print == 1) {
         if (iter%10 == 0 && rank == 0) printf("Iter %d\n",iter);
         Cartesian_print(x, jmax, imax, nhalo, nprocy, nprocx);
      }
   }
   total_time = cpu_timer_stop(tstart_total);

   if (rank == 0){
      printf("\nGhostExchange_ArrayAssign_HIP Timing is stencil %f boundary condition %f ghost cell %lf total %f\n",
             stencil_time,boundarycondition_time,ghostcell_time,total_time);
   }

   malloc2D_free(x, nhalo);
   malloc2D_free(xnew, nhalo);

   MPI_Finalize();
   exit(0);
}

void boundarycondition_update(double **x, int nhalo, int jsize, int isize, int nleft, int nrght, int nbot, int ntop)
{
   struct timespec tstart_boundarycondition;
   cpu_timer_start(&tstart_boundarycondition);

   dim3 gridVrt((nhalo+3)/4, (jsize+63)/64, 1);
   dim3 blockVrt(4, 64, 1);
   dim3 gridHor((isize+2*nhalo+63)/64, (nhalo+3)/4, 1);
   dim3 blockHor(64, 4, 1);

// Boundary conditions -- constant
   if (nleft == MPI_PROC_NULL){

      enforce_bcs_left <<< gridVrt, blockVrt >>> (x, nhalo, jsize);
      hipDeviceSynchronize();

   }

   if (nrght == MPI_PROC_NULL){

      enforce_bcs_rght <<< gridVrt, blockVrt >>> (x, nhalo, jsize, isize);
      hipDeviceSynchronize();

   }

   if (nbot == MPI_PROC_NULL){

      enforce_bcs_bot <<< gridHor, blockHor >>> (x, nhalo, isize);
      hipDeviceSynchronize();

   }
      
   if (ntop == MPI_PROC_NULL){

      enforce_bcs_top <<< gridHor, blockHor >>> (x, nhalo, jsize, isize);
      hipDeviceSynchronize();

   }

   boundarycondition_time += cpu_timer_stop(tstart_boundarycondition);
}

void ghostcell_update(double **x, int nhalo, int corners, int jsize, int isize, int nleft, int nrght, int nbot, int ntop, int do_timing)
{
   //if (do_timing) MPI_Barrier(MPI_COMM_WORLD);

   struct timespec tstart_ghostcell;
   cpu_timer_start(&tstart_ghostcell);

   MPI_Request request[4*nhalo];
   MPI_Status status[4*nhalo];

   int jlow=0, jhgh=jsize;
   if (corners) {
      if (nbot == MPI_PROC_NULL) jlow = -nhalo;
      if (ntop == MPI_PROC_NULL) jhgh = jsize+nhalo;
   }
   int jnum = jhgh-jlow;
   int bufcount = jnum*nhalo;

   double xbuf_left_send[bufcount];
   double xbuf_rght_send[bufcount];
   double xbuf_rght_recv[bufcount];
   double xbuf_left_recv[bufcount];

   dim3 gridGhst((nhalo+3)/4, (jnum+63)/64, 1);
   dim3 blockGhst(4, 64, 1);

   if (nleft != MPI_PROC_NULL){

      ghost_left_send <<< gridGhst, blockGhst >>> (xbuf_left_send, x, jlow, jhgh, nhalo, bufcount);
      hipDeviceSynchronize();

   }

   if (nrght != MPI_PROC_NULL){

      ghost_rght_send <<< gridGhst, blockGhst >>> (xbuf_rght_send, x, jlow, jhgh, isize, nhalo, bufcount);
      hipDeviceSynchronize();

   }

   MPI_Irecv(&xbuf_rght_recv, bufcount, MPI_DOUBLE, nrght, 1001,
             MPI_COMM_WORLD, &request[0]);
   MPI_Isend(&xbuf_left_send, bufcount, MPI_DOUBLE, nleft, 1001,
             MPI_COMM_WORLD, &request[1]);

   MPI_Irecv(&xbuf_left_recv, bufcount, MPI_DOUBLE, nleft, 1002,
             MPI_COMM_WORLD, &request[2]);
   MPI_Isend(&xbuf_rght_send, bufcount, MPI_DOUBLE, nrght, 1002,
             MPI_COMM_WORLD, &request[3]);
   MPI_Waitall(4, request, status);

   if (nrght != MPI_PROC_NULL){

      ghost_rght_recv <<< gridGhst, blockGhst >>> (xbuf_rght_recv, x, jlow, jhgh, isize, nhalo, bufcount);
      hipDeviceSynchronize();

   }

   if (nleft != MPI_PROC_NULL){

      ghost_left_recv <<< gridGhst, blockGhst >>>  (xbuf_left_recv, x, jlow, jhgh, nhalo, bufcount);
      hipDeviceSynchronize();

   }

   if (corners) {
      bufcount = nhalo*(isize+2*nhalo);
      MPI_Irecv(&x[jsize][-nhalo],   bufcount, MPI_DOUBLE, ntop, 1001, MPI_COMM_WORLD, &request[0]);
      MPI_Isend(&x[0    ][-nhalo],   bufcount, MPI_DOUBLE, nbot, 1001, MPI_COMM_WORLD, &request[1]);

      MPI_Irecv(&x[     -nhalo][-nhalo], bufcount, MPI_DOUBLE, nbot, 1002, MPI_COMM_WORLD, &request[2]);
      MPI_Isend(&x[jsize-nhalo][-nhalo], bufcount, MPI_DOUBLE, ntop, 1002, MPI_COMM_WORLD, &request[3]);
      MPI_Waitall(4, request, status);
   } else {
      for (int j = 0; j<nhalo; j++){
         MPI_Irecv(&x[jsize+j][0],   isize, MPI_DOUBLE, ntop, 1001+j*2, MPI_COMM_WORLD, &request[0+j*4]);
         MPI_Isend(&x[0+j    ][0],   isize, MPI_DOUBLE, nbot, 1001+j*2, MPI_COMM_WORLD, &request[1+j*4]);

         MPI_Irecv(&x[     -nhalo+j][0], isize, MPI_DOUBLE, nbot, 1002+j*2, MPI_COMM_WORLD, &request[2+j*4]);
         MPI_Isend(&x[jsize-nhalo+j][0], isize, MPI_DOUBLE, ntop, 1002+j*2, MPI_COMM_WORLD, &request[3+j*4]);
         }
      MPI_Waitall(4*nhalo, request, status);
   }

   //if (do_timing) MPI_Barrier(MPI_COMM_WORLD);

   ghostcell_time += cpu_timer_stop(tstart_ghostcell);
}

void haloupdate_test(int nhalo, int corners, int jsize, int isize, int nleft, int nrght, int nbot, int ntop,
      int jmax, int imax, int nprocy, int nprocx, int do_timing, int do_print)
{

   // NOTE: this function has not been ported to HIP
   int rank;
   MPI_Comm_rank(MPI_COMM_WORLD, &rank);
   double** x = malloc2D(jsize+2*nhalo, isize+2*nhalo, nhalo, nhalo);

   if (jsize > 12 || isize > 12) return;

   for (int j = -nhalo; j < jsize+nhalo; j++){
      for (int i = -nhalo; i < isize+nhalo; i++){
         x[j][i] = 0.0;
      }
   }

   for (int j = 0; j < jsize; j++){
      for (int i = 0; i < isize; i++){
         x[j][i] = rank * 1000 + j*10 + i;
      }
   }

   boundarycondition_update(x, nhalo, jsize, isize, nleft, nrght, nbot, ntop);
   ghostcell_update(x, nhalo, corners, jsize, isize, nleft, nrght, nbot, ntop, do_timing);

   if (do_print == 1) {
      Cartesian_print(x, jmax, imax, nhalo, nprocy, nprocx);
   }

   malloc2D_free(x, nhalo);
}

void parse_input_args(int argc, char **argv, int &jmax, int &imax, int &nprocy, int &nprocx, int &nhalo, int &corners, int &maxIter, int &do_timing, int &do_print)
{
   int c;
   int rank;
   MPI_Comm_rank(MPI_COMM_WORLD, &rank);

   while ((c = getopt(argc, argv, "cph:I:i:j:tx:y:")) != -1){
      switch(c){
         case 'c':
            corners = 1;
            break;
         case 'h':
            nhalo = atoi(optarg);
            break;
         case 'I':
            maxIter = atoi(optarg);
            break;
         case 'i':
            imax = atoi(optarg);
            break;
         case 'j':
            jmax = atoi(optarg);
            break;
         case 't':
            do_timing = 1;
            break;
         case 'p':
            do_print = 1;
            break;
         case 'x':
            nprocx = atoi(optarg);
            break;
         case 'y':
            nprocy = atoi(optarg);
            break;
         case '?':
            if (optopt == 'h' || optopt == 'I' || optopt == 'i' || optopt == 'j' || optopt == 'x' || optopt == 'y'){
               if (rank == 0) fprintf (stderr, "Option -%c requires an argument.\n", optopt);
               MPI_Finalize();
               exit(1);
            }
            break;
         default:
            if (rank == 0) fprintf(stderr,"Unknown option %c\n",c);
            MPI_Finalize();
            exit(1);
      }
   }

   int xcoord = rank%nprocx;
   int ycoord = rank/nprocx;

   int ibegin = imax *(xcoord  )/nprocx;
   int iend   = imax *(xcoord+1)/nprocx;
   int isize  = iend - ibegin;
   int jbegin = jmax *(ycoord  )/nprocy;
   int jend   = jmax *(ycoord+1)/nprocy;
   int jsize  = jend - jbegin;

   int ierr = 0, ierr_global;
   if (isize < nhalo || jsize < nhalo) {
      if (rank == 0) printf("Error -- local size of grid is less than the halo size\n");
      ierr = 1;
   }
   MPI_Allreduce(&ierr, &ierr_global, 1, MPI_INT, MPI_MAX, MPI_COMM_WORLD);
   if (ierr_global > 0) {
      MPI_Finalize();
      exit(0);
   }
}

void Cartesian_print(double **x, int jmax, int imax, int nhalo, int nprocy, int nprocx)
{
   int rank, nprocs;
   MPI_Comm_rank(MPI_COMM_WORLD, &rank);
   MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

   int isize_total=0;
   int isizes[nprocx];
   for (int ii = 0; ii < nprocx; ii++){
      int xcoord = ii%nprocx;
      int ycoord = ii/nprocx;
      int ibegin = imax *(xcoord  )/nprocx;
      int iend   = imax *(xcoord+1)/nprocx;
      isizes[ii] = iend-ibegin;
      isize_total += isizes[ii] + 2*nhalo;
   }

   if (isize_total > 100) return;

   if (rank == 0) {
      printf("     ");
      for (int ii = 0; ii < nprocx; ii++){
         for (int i = -nhalo; i < isizes[ii]+nhalo; i++){
            printf("%6d   ",i);
         }
         printf("   ");
      }
      printf("\n");
   }

   int xcoord = rank%nprocx;
   int ycoord = rank/nprocx;

   int ibegin = imax *(xcoord  )/nprocx;
   int iend   = imax *(xcoord+1)/nprocx;
   int isize  = iend - ibegin;
   int jbegin = jmax *(ycoord  )/nprocy;
   int jend   = jmax *(ycoord+1)/nprocy;
   int jsize  = jend - jbegin;

   double *xrow = (double *)malloc(isize_total*sizeof(double));
   for (int jj=nprocy-1; jj >= 0; jj--){
      int ilen = 0;
      int jlen = 0;
      int jlen_max;
      int *ilen_global = (int *)malloc(nprocs*sizeof(int));
      int *ilen_displ = (int *)malloc(nprocs*sizeof(int));
      if (ycoord == jj) {
         ilen = isize + 2*nhalo;
         jlen = jsize;
      }
      MPI_Allgather(&ilen,1,MPI_INT,ilen_global,1,MPI_INT,MPI_COMM_WORLD);
      MPI_Allreduce(&jlen,&jlen_max,1,MPI_INT,MPI_MAX,MPI_COMM_WORLD);
      ilen_displ[0] = 0;
      for (int i=1; i<nprocs; i++){
         ilen_displ[i] = ilen_displ[i-1] + ilen_global[i-1];
      }
      for (int j=jlen_max+nhalo-1; j>=-nhalo; j--){
         MPI_Gatherv(&x[j][-nhalo],ilen,MPI_DOUBLE,xrow,ilen_global,ilen_displ,MPI_DOUBLE,0,MPI_COMM_WORLD);
         if (rank == 0) {
            printf("%3d:",j);
            for (int ii = 0; ii < nprocx; ii++){
               for (int i = 0; i< isizes[ii]+2*nhalo; i++){
                  printf("%8.1lf ",xrow[i+ii*(isizes[ii]+2*nhalo)]);
               }
               printf("   ");
            }
            printf("\n");
         }
      }
      free(ilen_global);
      free(ilen_displ);
      if (rank == 0) printf("\n");
   }
   free(xrow);
}
