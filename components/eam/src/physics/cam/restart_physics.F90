module restart_physics

  use shr_kind_mod,       only: r8 => shr_kind_r8
  use spmd_utils,         only: masterproc
  use co2_cycle,          only: co2_transport
  use constituents,       only: pcnst
  use comsrf,             only: sgh, sgh30, trefmxav, trefmnav, initialize_comsrf 
  use ioFileMod
  use cam_abortutils,     only: endrun
  use camsrfexch,         only: cam_in_t, cam_out_t
  use cam_control_mod,    only: adiabatic, ideal_phys
  use cam_logfile,        only: iulog
  use pio,                only: file_desc_t, io_desc_t, var_desc_t, &
                                pio_double, pio_int, pio_noerr, &
                                pio_seterrorhandling, pio_bcast_error, &
                                pio_inq_varid, &
                                pio_def_var, pio_def_dim, &
                                pio_put_var, pio_get_var
  use cospsimulator_intr, only: docosp
  use radiation,          only: cosp_cnt_init, cosp_cnt, rad_randn_seedrst, kiss_seed_num

  implicit none
  private
  save
!
! Public interfaces
!
  public :: write_restart_physics    ! Write the physics restart info out
  public :: read_restart_physics     ! Read the physics restart info in
  public :: init_restart_physics

!
! Private data
!
    character(len=256) :: pname  ! Full abs-ems restart filepath
    character(len=8)   :: num

    logical           :: pergro_mods = .false.

    type(var_desc_t) :: trefmxav_desc, trefmnav_desc, flwds_desc, sgh_desc, &
         sgh30_desc, solld_desc, co2prog_desc, co2diag_desc, sols_desc, soll_desc, &
         solsd_desc, emstot_desc, absnxt_desc(4)

    type(var_desc_t) :: bcphidry_desc, bcphodry_desc, ocphidry_desc, ocphodry_desc, &
       dstdry1_desc, dstdry2_desc, dstdry3_desc, dstdry4_desc

    type(var_desc_t) :: cflx_desc(pcnst), lhf_desc, shf_desc

    type(var_desc_t), allocatable :: abstot_desc(:)

    type(var_desc_t) :: cospcnt_desc, rad_randn_seedrst_desc

  CONTAINS
    subroutine init_restart_physics ( File, pbuf2d)
      
    use physics_buffer,      only: pbuf_init_restart, physics_buffer_desc
    use radiation,           only: radiation_do
    use ppgrid,              only: pver, pverp, pcols
    use chemistry,           only: chem_init_restart
    use prescribed_ozone,    only: init_prescribed_ozone_restart
    use prescribed_ghg,      only: init_prescribed_ghg_restart
    use prescribed_aero,     only: init_prescribed_aero_restart
    use prescribed_volcaero, only: init_prescribed_volcaero_restart
    use cam_grid_support,    only: cam_grid_write_attr, cam_grid_id
    use cam_grid_support,    only: cam_grid_header_info_t
    use cam_pio_utils,       only: cam_pio_def_dim
    use subcol_utils,        only: is_subcol_on
    use subcol,              only: subcol_init_restart
    use phys_control,        only: phys_getopts

    type(file_desc_t), intent(inout) :: file
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)

    integer                      :: grid_id
    integer                      :: hdimcnt, ierr, i, vsize
    integer                      :: dimids(4)
    integer, allocatable         :: hdimids(:)
    integer                      :: ndims, pver_id, pverp_id
    integer                      :: kiss_seed_dim

    type(cam_grid_header_info_t) :: info

    call phys_getopts(pergro_mods_out = pergro_mods)

    call pio_seterrorhandling(File, PIO_BCAST_ERROR)
    ! Probably should have the grid write this out.
    grid_id = cam_grid_id('physgrid')
    call cam_grid_write_attr(File, grid_id, info)
    hdimcnt = info%num_hdims()

    do i = 1, hdimcnt
      dimids(i) = info%get_hdimid(i)
    end do
    allocate(hdimids(hdimcnt))
    hdimids(1:hdimcnt) = dimids(1:hdimcnt)

    call cam_pio_def_dim(File, 'lev', pver, pver_id, existOK=.true.)
    call cam_pio_def_dim(File, 'ilev', pverp, pverp_id, existOK=.true.)

    ndims=hdimcnt

    ndims=hdimcnt+1

    call pbuf_init_restart(File, pbuf2d)

    if ( .not. adiabatic .and. .not. ideal_phys )then
       
       call chem_init_restart(File)

       call init_prescribed_ozone_restart(File)
       call init_prescribed_ghg_restart(File)
       call init_prescribed_aero_restart(File)
       call init_prescribed_volcaero_restart(File)


       call cam_pio_def_dim(File, 'pcnst', pcnst, dimids(hdimcnt+1), existOK=.true.)
    
       ierr = pio_def_var(File, 'SGH',      pio_double, hdimids, sgh_desc)
       ierr = pio_def_var(File, 'SGH30',    pio_double, hdimids, sgh30_desc)
       ierr = pio_def_var(File, 'TREFMXAV', pio_double, hdimids, trefmxav_desc)
       ierr = pio_def_var(File, 'TREFMNAV', pio_double, hdimids, trefmnav_desc)
       
       ierr = pio_def_var(File, 'FLWDS', pio_double, hdimids, flwds_desc)
       ierr = pio_def_var(File, 'SOLS', pio_double, hdimids, sols_desc)
       ierr = pio_def_var(File, 'SOLL', pio_double, hdimids, soll_desc)
       ierr = pio_def_var(File, 'SOLSD', pio_double, hdimids, solsd_desc)
       ierr = pio_def_var(File, 'SOLLD', pio_double, hdimids, solld_desc)

       ierr = pio_def_var(File, 'BCPHIDRY', pio_double, hdimids, bcphidry_desc)
       ierr = pio_def_var(File, 'BCPHODRY', pio_double, hdimids, bcphodry_desc)
       ierr = pio_def_var(File, 'OCPHIDRY', pio_double, hdimids, ocphidry_desc)
       ierr = pio_def_var(File, 'OCPHODRY', pio_double, hdimids, ocphodry_desc)
       ierr = pio_def_var(File, 'DSTDRY1',  pio_double, hdimids, dstdry1_desc)
       ierr = pio_def_var(File, 'DSTDRY2',  pio_double, hdimids, dstdry2_desc)
       ierr = pio_def_var(File, 'DSTDRY3',  pio_double, hdimids, dstdry3_desc)
       ierr = pio_def_var(File, 'DSTDRY4',  pio_double, hdimids, dstdry4_desc)

       if(co2_transport()) then
          ierr = pio_def_var(File, 'CO2PROG', pio_double, hdimids, co2prog_desc)
          ierr = pio_def_var(File, 'CO2DIAG', pio_double, hdimids, co2diag_desc)
       end if

       ! cam_import variables -- write the constituent surface fluxes as individual 2D arrays
       ! rather than as a single variable with a pcnst dimension.  Note that the cflx components
       ! are only needed for those constituents that are not passed to the coupler.  The restart
       ! for constituents passed through the coupler are handled by the .rs. restart file.  But
       ! we don't currently have a mechanism to know whether the constituent is handled by the
       ! coupler or not, so we write all of cflx to the CAM restart file.
       do i = 1, pcnst
          write(num,'(i4.4)') i
          ierr = pio_def_var(File, 'CFLX'//num,  pio_double, hdimids, cflx_desc(i))
       end do
       ! Add LHF and SHF to restart file to fix non-BFB restart issue due to qneg4 correction at the restart time step
       ierr = pio_def_var(File, 'LHF',  pio_double, hdimids, lhf_desc)
       ierr = pio_def_var(File, 'SHF',  pio_double, hdimids, shf_desc)

    end if

    if (docosp) then
      ierr = pio_def_var(File, 'cosp_cnt_init', pio_int, cospcnt_desc)
    end if

    if (is_subcol_on()) then
      call subcol_init_restart(file, hdimids)
    end if

    if (pergro_mods) then
       call cam_pio_def_dim(File, 'kiss_seeds_dim', kiss_seed_num, kiss_seed_dim, existOK=.false.)
       dimids(hdimcnt+1) = kiss_seed_dim
       ierr = pio_def_var(File, 'rad_randn_seedrst', pio_int, dimids(1:hdimcnt+1), rad_randn_seedrst_desc)
    endif
      
  end subroutine init_restart_physics

  subroutine write_restart_physics (File, cam_in, cam_out, pbuf2d)

      !-----------------------------------------------------------------------
      use physics_buffer,      only: physics_buffer_desc, pbuf_write_restart
      use phys_grid,           only: phys_decomp
      
      use ppgrid,              only: begchunk, endchunk, pcols, pverp
      use chemistry,           only: chem_write_restart
      use prescribed_ozone,    only: write_prescribed_ozone_restart
      use prescribed_ghg,      only: write_prescribed_ghg_restart
      use prescribed_aero,     only: write_prescribed_aero_restart
      use prescribed_volcaero, only: write_prescribed_volcaero_restart
      use radiation,           only: radiation_do
      use cam_history_support, only: fillvalue
      use spmd_utils,          only: iam
      use cam_grid_support,    only: cam_grid_write_dist_array, cam_grid_id
      use cam_grid_support,    only: cam_grid_get_decomp, cam_grid_dimensions
      use cam_grid_support,    only: cam_grid_write_var
      use pio,                 only: pio_write_darray
      use subcol_utils,        only: is_subcol_on
      use subcol,              only: subcol_write_restart
      !
      ! Input arguments
      !
      type(file_desc_t), intent(inout) :: File
      type(cam_in_t),    intent(in)    :: cam_in(begchunk:endchunk)
      type(cam_out_t),   intent(in)    :: cam_out(begchunk:endchunk)
      type(physics_buffer_desc), pointer        :: pbuf2d(:,:)
      !
      ! Local workspace
      !
      type(io_desc_t), pointer :: iodesc
      real(r8):: tmpfield(pcols, begchunk:endchunk)
      integer :: tmp_seedrst(pcols, kiss_seed_num, begchunk:endchunk)
      integer :: i, m, iseed, icol          ! loop index
      integer :: ncol          ! number of vertical columns
      integer :: ierr
      integer :: physgrid
      integer :: dims(3), gdims(3)
      integer :: nhdims
      !-----------------------------------------------------------------------

      ! Write grid vars
      call cam_grid_write_var(File, phys_decomp)

      ! Physics buffer
      if (is_subcol_on()) then
         call subcol_write_restart(File)
      end if

      call pbuf_write_restart(File, pbuf2d)

      physgrid = cam_grid_id('physgrid')
      call cam_grid_dimensions(physgrid, gdims(1:2), nhdims)

      if ( .not. adiabatic .and. .not. ideal_phys )then

         ! data for chemistry
         call chem_write_restart(File)

         call write_prescribed_ozone_restart(File)
         call write_prescribed_ghg_restart(File)
         call write_prescribed_aero_restart(File)
         call write_prescribed_volcaero_restart(File)
 
         do i=begchunk,endchunk
            ncol = cam_out(i)%ncol
            if(ncol<pcols) then
               sgh(ncol+1:pcols,i) = fillvalue
               sgh30(ncol+1:pcols,i) = fillvalue

               trefmxav(ncol+1:pcols,i) = fillvalue
               trefmnav(ncol+1:pcols,i) = fillvalue
            end if
         end do

         ! Comsrf module variables (can following coup_csm definitions be removed?)
         ! This is a group of surface variables so can reuse dims
         dims(1) = size(sgh, 1) ! Should be pcols
         dims(2) = size(sgh, 2) ! Should be endchunk - begchunk + 1
         call cam_grid_get_decomp(physgrid, dims(1:2), gdims(1:nhdims),          &
              pio_double, iodesc)
         call pio_write_darray(File, sgh_desc,   iodesc,   sgh, ierr)
         call pio_write_darray(File, sgh30_desc, iodesc, sgh30, ierr)
         
         call pio_write_darray(File, trefmxav_desc, iodesc, trefmxav, ierr)
         call pio_write_darray(File, trefmnav_desc, iodesc, trefmnav, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%flwds(:ncol)
            ! Only have to do this once (cam_in/out vars all same shape)
            if (ncol < pcols) then
               tmpfield(ncol+1:, i) = fillvalue
            end if
         end do
         call pio_write_darray(File, flwds_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%sols(:ncol)
         end do
         call pio_write_darray(File, sols_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%soll(:ncol)
         end do
         call pio_write_darray(File, soll_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%solsd(:ncol)
         end do
         call pio_write_darray(File, solsd_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%solld(:ncol)
         end do
         call pio_write_darray(File, solld_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%bcphidry(:ncol)
         end do
         call pio_write_darray(File, bcphidry_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%bcphodry(:ncol)
         end do
         call pio_write_darray(File, bcphodry_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%ocphidry(:ncol)
         end do
         call pio_write_darray(File, ocphidry_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%ocphodry(:ncol)
         end do
         call pio_write_darray(File, ocphodry_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%dstdry1(:ncol)
         end do
         call pio_write_darray(File, dstdry1_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%dstdry2(:ncol)
         end do
         call pio_write_darray(File, dstdry2_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%dstdry3(:ncol)
         end do
         call pio_write_darray(File, dstdry3_desc, iodesc, tmpfield, ierr)

         do i = begchunk, endchunk
            ncol = cam_out(i)%ncol
            tmpfield(:ncol, i) = cam_out(i)%dstdry4(:ncol)
         end do
         call pio_write_darray(File, dstdry4_desc, iodesc, tmpfield, ierr)

         if (co2_transport()) then
            do i = begchunk, endchunk
               ncol = cam_out(i)%ncol
               tmpfield(:ncol, i) = cam_out(i)%co2prog(:ncol)
            end do
            call pio_write_darray(File, co2prog_desc, iodesc, tmpfield, ierr)

            do i = begchunk, endchunk
               ncol = cam_out(i)%ncol
               tmpfield(:ncol, i) = cam_out(i)%co2diag(:ncol)
            end do
            call pio_write_darray(File, co2diag_desc, iodesc, tmpfield, ierr)
         end if

         ! cam_in components
         do m = 1, pcnst
            do i = begchunk, endchunk
               ncol = cam_in(i)%ncol
               tmpfield(:ncol, i) = cam_in(i)%cflx(:ncol, m)
            end do
            call pio_write_darray(File, cflx_desc(m), iodesc, tmpfield, ierr)
         end do

         do i = begchunk, endchunk
            ncol = cam_in(i)%ncol
            tmpfield(:ncol, i) = cam_in(i)%lhf(:ncol)
         end do
         call pio_write_darray(File, lhf_desc, iodesc, tmpfield, ierr)
         do i = begchunk, endchunk
            ncol = cam_in(i)%ncol
            tmpfield(:ncol, i) = cam_in(i)%shf(:ncol)
         end do
         call pio_write_darray(File, shf_desc, iodesc, tmpfield, ierr)

      end if

      if (docosp) then
        ierr = pio_put_var(File, cospcnt_desc, (/cosp_cnt(begchunk)/))
      end if

      if (pergro_mods) then
         do i  = begchunk, endchunk
            ncol = cam_out(i)%ncol
            do iseed = 1 , kiss_seed_num             
               do icol = 1, ncol
                  tmp_seedrst(icol,iseed,i) = rad_randn_seedrst(icol,iseed,i)
               enddo
               if(ncol < pcols) then
                  tmp_seedrst(ncol+1:pcols,iseed,i) = huge(1)
               end if
            enddo
         enddo
         
         dims(1) = size(tmp_seedrst, 1) ! Should be pcols
         dims(2) = size(tmp_seedrst, 2) ! Should be kiss_seed_num
         dims(3) = size(tmp_seedrst, 3) ! Should be endchunk - begchunk + 1
         gdims(nhdims+1) = kiss_seed_num
         call cam_grid_write_dist_array(File, physgrid, dims(1:3),             &
              gdims(1:nhdims+1), tmp_seedrst, rad_randn_seedrst_desc)
      endif
      
    end subroutine write_restart_physics

!#######################################################################

    subroutine read_restart_physics(File, cam_in, cam_out, pbuf2d)

     !-----------------------------------------------------------------------
     use physics_buffer,      only: physics_buffer_desc, pbuf_read_restart
     
     use ppgrid,              only: begchunk, endchunk, pcols, pver, pverp
     use chemistry,           only: chem_read_restart
     use cam_grid_support,    only: cam_grid_read_dist_array, cam_grid_id
     use cam_grid_support,    only: cam_grid_get_decomp, cam_grid_dimensions
     use cam_history_support, only: fillvalue
     use radiation,           only: radiation_do
     use prescribed_ozone,    only: read_prescribed_ozone_restart
     use prescribed_ghg,      only: read_prescribed_ghg_restart
     use prescribed_aero,     only: read_prescribed_aero_restart
     use prescribed_volcaero, only: read_prescribed_volcaero_restart
     use subcol_utils,        only: is_subcol_on
     use subcol,              only: subcol_read_restart
     use pio,                 only: pio_read_darray
     !
     ! Arguments
     !
     type(file_desc_t),   intent(inout) :: File
     type(cam_in_t),            pointer :: cam_in(:)
     type(cam_out_t),           pointer :: cam_out(:)
     type(physics_buffer_desc), pointer :: pbuf2d(:,:)
     !
     ! Local workspace
     !
     real(r8), allocatable :: tmpfield2(:,:)
     integer :: i, c, m           ! loop index
     integer :: ierr             ! I/O status
     type(io_desc_t), pointer :: iodesc
     type(var_desc_t)         :: vardesc
     integer                  :: csize, vsize
     character(len=4)         :: num
     integer                  :: dims(3), gdims(3), nhdims
     integer                  :: err_handling
     integer                  :: physgrid, astat
     !-----------------------------------------------------------------------

     ! Allocate memory in physics buffer and comsrf modules.
     ! (This is done in subroutine initial_conds for an initial run.)
     call initialize_comsrf()

     ! Physics buffer

     ! subcol_read_restart must be called before pbuf_read_restart
     if (is_subcol_on()) then
        call subcol_read_restart(File)
     end if

     call pbuf_read_restart(File, pbuf2d)

     csize=endchunk-begchunk+1
     dims(1) = pcols
     dims(2) = csize

     physgrid = cam_grid_id('physgrid')

     call cam_grid_dimensions(physgrid, gdims(1:2))

     if (gdims(2) == 1) then
       nhdims = 1
     else
       nhdims = 2
     end if
     
     call cam_grid_get_decomp(physgrid, dims(1:2), gdims(1:nhdims), pio_double, &
          iodesc)
     if ( .not. adiabatic .and. .not. ideal_phys )then

        ! data for chemistry
        call chem_read_restart(File)

        call read_prescribed_ozone_restart(File)
        call read_prescribed_ghg_restart(File)
        call read_prescribed_aero_restart(File)
        call read_prescribed_volcaero_restart(File)

        allocate(tmpfield2(pcols, begchunk:endchunk))
        tmpfield2 = fillvalue

        ierr = pio_inq_varid(File, 'SGH', vardesc)
        call pio_read_darray(File, vardesc, iodesc, sgh, ierr)

        ierr = pio_inq_varid(File, 'SGH30', vardesc)
        call pio_read_darray(File, vardesc, iodesc, sgh30, ierr)

        ierr = pio_inq_varid(File, 'TREFMXAV', vardesc)
        call pio_read_darray(File, vardesc, iodesc, trefmxav, ierr)

        ierr = pio_inq_varid(File, 'TREFMNAV', vardesc)
        call pio_read_darray(File, vardesc, iodesc, trefmnav, ierr)

        ierr = pio_inq_varid(File, 'FLWDS', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%flwds(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'SOLS', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%sols(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'SOLL', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%soll(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'SOLSD', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%solsd(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'SOLLD', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%solld(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'BCPHIDRY', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%bcphidry(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'BCPHODRY', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%bcphodry(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'OCPHIDRY', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%ocphidry(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'OCPHODRY', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%ocphodry(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'DSTDRY1', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%dstdry1(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'DSTDRY2', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%dstdry2(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'DSTDRY3', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%dstdry3(i) = tmpfield2(i, c)
           end do
        end do

        ierr = pio_inq_varid(File, 'DSTDRY4', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c=begchunk,endchunk
           do i=1,pcols
              cam_out(c)%dstdry4(i) = tmpfield2(i, c)
           end do
        end do

        if (co2_transport()) then
           ierr = pio_inq_varid(File, 'CO2PROG', vardesc)
           call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
           do c=begchunk,endchunk
              do i=1,pcols
                 cam_out(c)%co2prog(i) = tmpfield2(i, c)
              end do
           end do

           ierr = pio_inq_varid(File, 'CO2DIAG', vardesc)
           call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
           do c=begchunk,endchunk
              do i=1,pcols
                 cam_out(c)%co2diag(i) = tmpfield2(i, c)
              end do
           end do
        end if

        ! Reading the CFLX* components from the restart is optional for
        ! backwards compatibility.  These fields were not needed for an
        ! exact restart until the UNICON scheme was added, which has been 
        ! removed. More generally, these components are only needed if they 
        ! are not handled by the coupling layer restart (the ".rs." file), 
        ! and if the values are used in the tphysbc physics before the 
        ! tphysac code has a chance to update the values that are 
        ! coming from boundary datasets.
        do m = 1, pcnst

           write(num,'(i4.4)') m

           !!XXgoldyXX: This hack should be replaced with the PIO interface
           !err_handling = File%iosystem%error_handling !! Hack
           call pio_seterrorhandling(File, PIO_BCAST_ERROR, err_handling)
           ierr = pio_inq_varid(File, 'CFLX'//num, vardesc)
           call pio_seterrorhandling(File, err_handling)

           if (ierr == PIO_NOERR) then ! CFLX variable found on restart file
              call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
              do c= begchunk, endchunk
                 do i = 1, pcols
                    cam_in(c)%cflx(i,m) = tmpfield2(i, c)
                 end do
              end do
           end if

        end do

        ! Add LHF and SHF to restart file to fix non-BFB restart issue due to qneg4 update at the restart time step
        ! May want to check if LHF and SHF are present (to be back-compatible with restart files from older runs).
        ! In that case, if any qneg4 correction occurs at the restart time,
        ! non-BFB for the step needs to be tolerated (because the corrected
        ! LHF/SHF  not carried over thru restart file)
        ierr = pio_inq_varid(File, 'LHF', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c= begchunk, endchunk
           do i = 1, pcols
              cam_in(c)%lhf(i) = tmpfield2(i, c)
           end do
        end do
        ierr = pio_inq_varid(File, 'SHF', vardesc)
        call pio_read_darray(File, vardesc, iodesc, tmpfield2, ierr)
        do c= begchunk, endchunk
           do i = 1, pcols
              cam_in(c)%shf(i) = tmpfield2(i, c)
           end do
        end do

        deallocate(tmpfield2)

     end if

     if (docosp) then
        !!XXgoldyXX: This hack should be replaced with the PIO interface
        !err_handling = File%iosystem%error_handling !! Hack
        call pio_seterrorhandling( File, PIO_BCAST_ERROR, err_handling)
        ierr = pio_inq_varid(File, 'cosp_cnt_init', vardesc)
        call pio_seterrorhandling( File, err_handling)
        if(ierr/=PIO_NOERR) then
           cosp_cnt_init=0
        else
           ierr = pio_get_var(File, vardesc, cosp_cnt_init)
        end if
     end if

     if (pergro_mods) then
        dims(2) = kiss_seed_num
        dims(3) = csize
        gdims(nhdims+1) = dims(2)
        ierr = pio_inq_varid(File, 'rad_randn_seedrst', vardesc)
        if(ierr == PIO_NOERR) then
           allocate(rad_randn_seedrst(pcols,kiss_seed_num,begchunk:endchunk), stat=astat)
           if( astat /= 0 ) then
              if(masterproc)write(iulog,*) 'restart_physics.F90-read_restart_physics: failed to allocate rad_randn_seedrst; error = ',astat
              call endrun()
           end if
        
           call cam_grid_read_dist_array(File, physgrid, dims(1:3),           &
                gdims(1:nhdims+1), rad_randn_seedrst, vardesc)
        else
           if(masterproc)write(iulog,*) 'restart_physics.F90-read_restart_physics: unable to find rad_randn_seedrst variable in restart file; error = ',ierr
           call endrun()
        endif
     endif

   end subroutine read_restart_physics


 end module restart_physics
