#####################################################################
#A scalable and high-performance platform for R.
#Copyright (C) [2013] Hewlett-Packard Development Company, L.P.

#This program is free software; you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation; either version 2 of the License, or (at
#your option) any later version.

#This program is distributed in the hope that it will be useful, but
#WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#General Public License for more details.  You should have received a
#copy of the GNU General Public License along with this program; if
#not, write to the Free Software Foundation, Inc., 59 Temple Place,
#Suite 330, Boston, MA 02111-1307 USA
#####################################################################

update <- function(x,empty=FALSE) {
  name <- deparse(substitute(x))
  if(inherits(x, "dsCMatrix")) {
    coerce_x <- as(x, "dgCMatrix")
    assign(name, coerce_x, globalenv())
  } else if(inherits(x, "dgeMatrix")) { #dgeMatrix is a dense matrix type
    coerce_x <- as(x, "matrix")
    assign(name, coerce_x, globalenv())
  } else 
    assign(name, x, globalenv())

  #Find dimension of object  
  objdim<-as.numeric(dim(x))
  if(is.null(objdim) || length(objdim)==0) objdim <-c(0,0) #For lists, numeric values, and non-matrix types etc.
  if(length(objdim)==1) objdim<-c(1,objdim) #Vectors have one dimension
  if(length(objdim)!=2) stop("Executor error: Can't figure out dimension of updated object")

  if(inherits(x, "matrix") || inherits(x, "numeric")) {
     if((objdim[1]*objdim[2] > .Machine$integer.max) || all(objdim<=.Machine$integer.max) == FALSE)
        stop(paste("Executor error: Cannot create darray partition with dimension larger than", .Machine$integer.max,
                   "or number of elements more than",.Machine$integer.max))
  } else if (inherits(x, "dgTMatrix") || inherits(x, "dgCMatrix")) {
     # Get non-zero elements of the sparse matrix using its 'i' slot
     if((length(x@i) > .Machine$integer.max) || all(objdim<=.Machine$integer.max) == FALSE)
        stop(paste("Executor error: Cannot create sparse darray partition with dimension larger than", .Machine$integer.max,
                    "or number of elements more than", .Machine$integer.max))
  } else if(inherits(x, "data.frame")) {
     if(all(objdim<=.Machine$integer.max) == FALSE)
        stop(paste("Executor error: Cannot create dframe partition with dimension larger than", .Machine$integer.max))
  }  

  .Call("NewUpdate", get("updates.ptr..."), name, empty, objdim,
        DUP=FALSE)
}

# get (x,y) offsets of split with index
dobject.getoffsets <- function(fulldim, blockdim, index) {
  blocks <- ceiling(fulldim/blockdim)
  block.x <- (index-1)%/%blocks[2]+1
  block.y <- (index-1)%%blocks[2]+1
  return(c((block.x-1)*blockdim[1], (block.y-1)*blockdim[2]))
}
         
# get dims of split with index
dobject.getdims <- function(fulldim, blockdim, index) {
  res <- c(1,1)

  blocks <- ceiling(fulldim/blockdim)
  block.x <- (index-1)%/%blocks[2]+1
  block.y <- (index-1)%%blocks[2]+1

  if (block.x < blocks[1]) {
    res[1] <- blockdim[1]
  } else {
    if (fulldim[1]%%blockdim[1] == 0) {
      res[1] <- blockdim[1]
    } else {
      res[1] <- fulldim[1]%%blockdim[1]
    }
  }

  if (block.y < blocks[2]) {
    res[2] <- blockdim[2]
  } else {
    if (fulldim[2]%%blockdim[2] == 0) {
      res[2] <- blockdim[2]
    } else {
      res[2] <- fulldim[2]%%blockdim[2]
    }
  }
  return(as.integer(res))
}

checkdims <- function(x, y) {
  return(dim(x)[2] == dim(y)[1])
}

setMethod("%*%", signature(x = "numeric", y = "dgCMatrix"),
	  function(x, y) {
            if (checkdims(x, y)) {
              return(.Call("spvm", x, y, as.integer(1), PACKAGE="MatrixHelper"))
            } else {
              stop("arg dimensions do not match")
            }
            })

setMethod("%*%", signature(x = "matrix", y = "dgCMatrix"),
	  function(x, y) {
            if (checkdims(x, y)) {
              return(.Call("spvm", x, y, dim(x)[1], PACKAGE="MatrixHelper"))
            } else {
              stop("arg dimensions do not match")
            }
            })

setMethod("%*%", signature(x = "dgCMatrix", y = "numeric"),
	  function(x, y) {
            if (checkdims(x, y)) {
              return(.Call("spmv", x, y, as.integer(1), PACKAGE="MatrixHelper"))
            } else {
              stop("arg dimensions do not match")
            }
            })

setMethod("%*%", signature(x = "dgCMatrix", y = "matrix"),
	  function(x, y) {
            if (checkdims(x, y)) {
              return(.Call("spmv", x, y, dim(y)[2], PACKAGE="MatrixHelper"))
            } else {
              stop("arg dimensions do not match")
            }
            })
