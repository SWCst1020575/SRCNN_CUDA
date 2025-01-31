/*******************************************************************************
 * SRCNN: Super-Resolution with deep Convolutional Neural Networks
 * ----------------------------------------------------------------------------
 * Current Author : Raphael Kim ( rageworx@gmail.com )
 * Latest update  : 2023-03-08
 * Pre-Author     : Wang Shu
 * Origin-Date    @ Sun 13 Sep, 2015
 * Descriptin ..
 *                 This source code modified version from Origianl code of Wang
 *                Shu's. All license following from origin.
 *******************************************************************************/
#ifndef EXPORTLIBSRCNN

////////////////////////////////////////////////////////////////////////////////
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <iomanip>
#include <iostream>
#include <string>
#ifndef NO_OMP
#include <omp.h>
#endif

#include "srcnn.h"
#include "tick.h"
#include "video.h"
/* pre-calculated convolutional data */
#include "convdata.h"
#include "convdataCuda.cuh"
////////////////////////////////////////////////////////////////////////////////

#define THREAD 256
#define BLOCK 2048

static float image_multiply = 2.0f;
static bool opt_verbose = true;
static bool opt_debug = false;
static bool opt_help = false;
static int t_exit_code = 0;

static std::string path_me;
static std::string file_me;
static std::string file_src;
static std::string file_dst;

pthread_mutex_t waitVideoMutex;
pthread_mutex_t videoCompleteMutex;
std::list<cv::Mat> frameList;
std::vector<cv::Mat> frameListComplete;
unsigned nb_frames;
unsigned completeFrame = 0;
bool isVideoComplete = false;
bool isVideo = false;

unsigned src_width = 0;
unsigned src_height = 0;
unsigned dst_width = 0;
unsigned dst_height = 0;

std::vector<cv::Mat> pImg(3);
std::vector<cv::Mat> pImgYCrCbCh(3);
cv::Mat pImgOrigin;
cv::Mat pImgYCrCb;
cv::Mat pImgYCrCbOut;
cv::Mat pImgBGROut;

////////////////////////////////////////////////////////////////////////////////

#define DEF_STR_VERSION "0.1.5.20"

////////////////////////////////////////////////////////////////////////////////

/* Function Declaration */
void Convolution99(cv::Mat& src, cv::Mat& dst,
                   const float kernel[9][9], float bias);

void Convolution11(std::vector<cv::Mat>& src, cv::Mat& dst,
                   const float kernel[CONV1_FILTERS], float bias);

__global__ void Convolution55(float* src, unsigned char* dst, int* rowf, int* colf, int height, int width);

__global__ void Convolution99x11(unsigned char* src, float* dst, int* rowf, int* colf, int height, int width);

////////////////////////////////////////////////////////////////////////////////
void setSrcSize(unsigned height, unsigned width) {
    src_height = height;
    src_width = width;
}
static inline int IntTrim(int a, int b, int c) {
    int buff[3] = {a, c, b};
    return buff[(int)(c > a) + (int)(c > b)];
}
__device__ static inline int IntTrimCuda(int a, int b, int c) {
    int buff[3] = {a, c, b};
    return buff[(int)(c > a) + (int)(c > b)];
}
/***
 * FuncName : Convolution99
 * Function : Complete one cell in the first Convolutional Layer
 * Parameter    : src - the original input image
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
void Convolution99(cv::Mat& src, cv::Mat& dst, const float kernel[9][9], float bias) {
    int width = dst.cols;
    int height = dst.rows;
    int row = 0;
    int col = 0;
    // macOS clang displays these array not be initialized.
    int rowf[height + 8];
    int colf[width + 8];

/* Expand the src image */
#pragma parallel for
    for (row = 0; row < height + 8; row++) {
        rowf[row] = IntTrim(0, height - 1, row - 4);
    }

#pragma parallel for
    for (col = 0; col < width + 8; col++) {
        colf[col] = IntTrim(0, width - 1, col - 4);
    }

/* Complete the Convolution Step */
#pragma omp parallel for private(col)
    for (row = 0; row < height; row++) {
        for (col = 0; col < width; col++) {
            /* Convolution */
            float temp = 0.f;

            for (int i = 0; i < 9; i++) {
                for (int j = 0; j < 9; j++) {
                    temp += kernel[i][j] * src.at<uint8_t>(rowf[row + i], colf[col + j]);
                }
            }

            temp += bias;

            /* Threshold */
            temp = (temp < 0) ? 0 : temp;

            dst.at<float>(row, col) = temp;
        }
    }
}

/***
 * FuncName : Convolution11
 * Function : Complete one cell in the second Convolutional Layer
 * Parameter    : src - the first layer data
 *        dst - the output data
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
void Convolution11(std::vector<cv::Mat>& src, cv::Mat& dst, const float kernel[CONV1_FILTERS], float bias) {
    int height = dst.rows;
    int width = dst.cols;
    int row = 0;
    int col = 0;

#pragma omp parallel for private(col)
    for (row = 0; row < height; row++) {
        for (col = 0; col < width; col++) {
            /* Process with each pixel */
            float temp = 0.f;

            for (int i = 0; i < CONV1_FILTERS; i++) {
                temp += src[i].at<float>(row, col) * kernel[i];
            }
            temp += bias;

            /* Threshold */
            temp = (temp < 0) ? 0 : temp;

            dst.at<float>(row, col) = temp;
        }
    }
}

/***
 * FuncName : Convolution55
 * Function : Complete the cell in the third Convolutional Layer
 * Parameter    : src - the second layer data
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
__global__ void Convolution55(float* src, unsigned char* dst, int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row = 0;
    int col = 0;

    /* Complete the Convolution Step */
    for (int id = idx; id < width * height; id += THREAD * BLOCK) {
        row = id / width;
        col = id % width;
        float temp = 0;
        for (int i = 0; i < CONV2_FILTERS; i++) {
            double temppixel = 0;
#pragma unroll
            for (int m = 0; m < 5; m++) {
#pragma unroll
                for (int n = 0; n < 5; n++) {
                    // temppixel +=
                    //     weights_conv3_data_cuda[i][m][n] * src[i].at<float>(rowf[row + m], colf[col + n]);
                    temppixel += weights_conv3_data_cuda[i][m][n] * src[i * width * height + rowf[row + m] * width + colf[col + n]];
                }
            }

            temp += temppixel;
        }

        temp += biases_conv3_cuda;

        /* Threshold */
        temp = IntTrimCuda(0, 255, temp);

        // dst.at<unsigned char>(row, col) = (unsigned char)temp;
        dst[row * width + col] = (unsigned char)temp;
    }
}

/***
 * FuncName : Convolution99x11
 * Function : Complete one cell in the first and second Convolutional Layer
 * Parameter    : src - the original input image
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
__global__ void intTrimData(int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    for (int i = idx; i < height + 8; i += blockDim.x * gridDim.x)
        rowf[i] = IntTrimCuda(0, height - 1, i - 4);
    for (int i = idx; i < width + 8; i += blockDim.x * gridDim.x)
        colf[i] = IntTrimCuda(0, width - 1, i - 4);
}
__global__ void intTrimData2(int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    for (int i = idx; i < height + 4; i += blockDim.x * gridDim.x)
        rowf[i] = IntTrimCuda(0, height - 1, i - 2);
    for (int i = idx; i < width + 4; i += blockDim.x * gridDim.x)
        colf[i] = IntTrimCuda(0, width - 1, i - 2);
}
__global__ void Convolution99x11(unsigned char* src, float* dst, int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row = 0;
    int col = 0;
    float temp[CONV1_FILTERS] = {0.f};
    /* Complete the Convolution Step */
    for (int id = idx; id < width * height; id += THREAD * BLOCK) {
        row = id / width;
        col = id % width;
        for (int k = 0; k < CONV1_FILTERS; k++) {
            /* Convolution */
            temp[k] = 0.0;
#pragma unroll
            for (int i = 0; i < 9; i++) {
#pragma unroll
                for (int j = 0; j < 9; j++) {
                    temp[k] += weights_conv1_data_cuda[k][i][j] * src[rowf[row + i] * width + colf[col + j]];
                    // temp[k] += weights_conv1_data_cuda[k][i][j] * src.at<uint8_t>(rowf[row + i], colf[col + j]);
                }
            }

            temp[k] += biases_conv1_cuda[k];

            /* Threshold */
            temp[k] = (temp[k] < 0) ? 0 : temp[k];
        }

        /* Process with each pixel */
        for (int k = 0; k < CONV2_FILTERS; k++) {
            float result = 0.0;
#pragma unroll
            for (int i = 0; i < CONV1_FILTERS; i++) {
                result += temp[i] * weights_conv2_data_cuda[k][i];
            }
            result += biases_conv2_cuda[k];

            /* Threshold */
            result = (result < 0) ? 0 : result;
            dst[k * width * height + row * width + col] = result;
            // dst[k].at<float>(row, col) = result;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

bool parseArgs(int argc, char** argv) {
    for (int cnt = 0; cnt < argc; cnt++) {
        std::string strtmp = argv[cnt];
        size_t fpos = std::string::npos;

        if (cnt == 0) {
            fpos = strtmp.find_last_of("\\");

            if (fpos == std::string::npos) {
                fpos = strtmp.find_last_of("/");
            }

            if (fpos != std::string::npos) {
                path_me = strtmp.substr(0, fpos);
                file_me = strtmp.substr(fpos + 1);
            } else {
                file_me = strtmp;
            }
        } else {
            if (strtmp.find("--scale=") == 0) {
                std::string strval = strtmp.substr(8);
                if (strval.size() > 0) {
                    float tmpfv = atof(strval.c_str());
                    if (tmpfv > 0.f) {
                        image_multiply = tmpfv;
                    }
                }
            } else if (strtmp.find("--noverbose") == 0) {
                opt_verbose = false;
            } else if (strtmp.find("--help") == 0) {
                opt_help = true;
            } else if (file_src.size() == 0) {
                file_src = strtmp;
            } else if (file_dst.size() == 0) {
                file_dst = strtmp;
            }
        }
    }

    if (!opt_help) {
        if ((file_src.size() > 0) && (file_dst.size() == 0)) {
            std::string convname = file_src;
            std::string srcext;

            // changes name without file extention.
            size_t posdot = file_src.find_last_of(".");
            if (posdot != std::string::npos) {
                convname = file_src.substr(0, posdot);
                srcext = file_src.substr(posdot);
            }

            convname += "_resized";
            if (srcext.size() > 0) {
                convname += srcext;
            }

            file_dst = convname;
        }
        if ((file_src.size() > 0) && (file_dst.size() > 0)) {
            return true;
        }
    }

    return false;
}

void printTitle() {
    printf("%s : Super-Resolution with deep Convolutional Neural Networks\n",
           file_me.c_str());
    printf("(C)2018..2023 Raphael Kim, (C)2014 Wang Shu., version %s\n",
           DEF_STR_VERSION);
    printf("Built with OpenCV version %s\n", CV_VERSION);
}

void printHelp() {
    printf("\n");
    printf("    usage : %s (options) [source file name] ([output file name])\n", file_me.c_str());
    printf("\n");
    printf("    _options_:\n");
    printf("\n");
    printf("        --scale=( ratio: 0.1 to .. ) : scaling by ratio.\n");
    printf("        --noverbose                  : turns off all verbose\n");
    printf("        --help                       : this help\n");
    printf("\n");
}

void* srcnnImage(void* p) {
    /* Read the original image */
    // Test image resize target ...
    cv::Size testsz = pImgOrigin.size();
    if ((((float)testsz.width * image_multiply) <= 0.f) ||
        (((float)testsz.height * image_multiply) <= 0.f)) {
        if (opt_verbose == true) {
            printf("- Image scale error : ratio too small.\n");
        }

        threadExit(-1);
    }
    dst_width = testsz.width * image_multiply;
    dst_height = testsz.height * image_multiply;
    // -------------------------------------------------------------
    if (opt_verbose == true) {
        printf("- Image converting to Y-Cr-Cb : ");
        fflush(stdout);
    }

    unsigned perf_tick0 = tick::getTickCount();

    /* Convert the image from BGR to YCrCb Space */
    auto start = tick::getCurrent();
    cvtColor(pImgOrigin, pImgYCrCb, CV_BGR2YCrCb);
    auto end = tick::getCurrent();
    if (pImgYCrCb.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u us\n", tick::getDiff(start, end));
            fflush(stdout);
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
        }

        threadExit(-2);
    }

    // ------------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Splitting channels : ");
        fflush(stdout);
    }

    /* Split the Y-Cr-Cb channel */
    start = tick::getCurrent();
    split(pImgYCrCb, pImgYCrCbCh);
    end = tick::getCurrent();
    if (pImgYCrCb.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u us\n", tick::getDiff(start, end));
            fflush(stdout);
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
            threadExit(-3);
        }
    }

    // ------------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Resizing splitted channels with bicublic interpolation : ");
    }

    /* Resize the Y-Cr-Cb Channel with Bicubic Interpolation */
    start = tick::getCurrent();
#pragma omp parallel for
    for (int i = 0; i < 3; i++) {
        cv::Size newsz = pImgYCrCbCh[i].size();
        newsz.width *= image_multiply;
        newsz.height *= image_multiply;

        resize(pImgYCrCbCh[i], pImg[i], newsz, 0, 0, CV_INTER_CUBIC);
    }
    end = tick::getCurrent();
    if (opt_verbose == true) {
        printf("Ok. %u us\n", tick::getDiff(start, end));
    }

    // -----------------------------------------------------------

    /******************* The First Layer *******************/

    if (opt_verbose == true) {
        printf("- Processing convolutional layer I + II ... ");
        fflush(stdout);
    }
    // first conv

    unsigned char* srcImg;
    float* firstConv;
    int* rowf;
    int* colf;
    unsigned char* dstImg;

    cudaMalloc(&rowf, (dst_height + 8) * sizeof(int));
    cudaMalloc(&colf, (dst_width + 8) * sizeof(int));
    cudaMalloc(&srcImg, dst_width * dst_height * sizeof(unsigned char));
    cudaMalloc(&firstConv, dst_width * dst_height * sizeof(float) * CONV2_FILTERS);
    cudaMalloc(&dstImg, dst_width * dst_height * sizeof(unsigned char));
    printf("\ncuda malloc complete\n");
    cudaMemcpy(srcImg, pImg[0].data, dst_width * dst_height * sizeof(unsigned char), cudaMemcpyHostToDevice);
    printf("cuda memcpy complete\n");

    intTrimData<<<16, THREAD>>>(rowf, colf, dst_height, dst_width);
    intTrimData2<<<16, THREAD>>>(rowf, colf, dst_height, dst_width);
    cudaDeviceSynchronize();
    printf("intTrim init complete\n");

    start = tick::getCurrent();
    Convolution99x11<<<BLOCK, THREAD>>>(srcImg, firstConv, rowf, colf, dst_height, dst_width);
    cudaDeviceSynchronize();
    end = tick::getCurrent();
    printf("cuda Convolution99x11 complete\n");
    printf("  Convolution: %u us.\n", tick::getDiff(start, end));
    if (opt_verbose == true) {
        printf("  completed.\n");
        fflush(stdout);
    }

    /******************* The Third Layer *******************/

    if (opt_verbose == true) {
        printf("- Processing convolutional layer III ... ");
        fflush(stdout);
    }
    // second conv

    start = tick::getCurrent();
    Convolution55<<<BLOCK, THREAD>>>(firstConv, dstImg, rowf, colf, dst_height, dst_width);
    unsigned char* convImg = (unsigned char*)malloc(dst_height * dst_width * sizeof(unsigned char));
    cudaDeviceSynchronize();
    printf("\ncuda Convolution55 complete\n");
    end = tick::getCurrent();

    cudaMemcpy(convImg, dstImg, dst_height * dst_width * sizeof(unsigned char), cudaMemcpyDeviceToHost);
    cv::Mat pImgConv3 = cv::Mat(pImg[0].size(), CV_8U, convImg).clone();
    free(convImg);

    printf("  Convolution: %u us.\n", tick::getDiff(start, end));
    if (opt_verbose == true) {
        printf("  completed.\n");
        printf("- Merging images : ");
        fflush(stdout);
    }

    /* Merge the Y-Cr-Cb Channel into an image */
    start = tick::getCurrent();
    pImg[0] = pImgConv3;
    merge(pImg, pImgYCrCbOut);
    end = tick::getCurrent();
    if (opt_verbose == true) {
        printf("Ok. %u us.\n", tick::getDiff(start, end));
        fflush(stdout);
    }

    // ---------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Converting channel to BGR : ");
        fflush(stdout);
    }

    /* Convert the image from YCrCb to BGR Space */
    start = tick::getCurrent();
    cvtColor(pImgYCrCbOut, pImgBGROut, CV_YCrCb2BGR);
    end = tick::getCurrent();
    unsigned perf_tick1 = tick::getTickCount();

    if (pImgBGROut.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u us.\n", tick::getDiff(start, end));
            printf("- Writing result to %s : ", file_dst.c_str());
            fflush(stdout);
        }

        imwrite(file_dst.c_str(), pImgBGROut);

        if (opt_verbose == true) {
            printf("Ok.\n");
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
        }
        threadExit(-10);
    }

    if (opt_verbose == true) {
        printf("- Performace : %u ms took.\n", perf_tick1 - perf_tick0);
    }

    fflush(stdout);

    threadExit(0);
    return NULL;
}

void* srcnnVideo(void* p) {
    /* Read the original image */

    // Test image resize target ...
    unsigned char* srcImg;
    float* firstConv;
    int *rowf, *rowf2;
    int *colf, *colf2;
    unsigned char* dstImg;
    unsigned frameNum = 1;
    pthread_mutex_lock(&waitVideoMutex);
    auto start = tick::getCurrent();
    if ((((float)src_width * image_multiply) <= 0.f) ||
        (((float)src_height * image_multiply) <= 0.f)) {
        if (opt_verbose == true) {
            printf("- Image scale error : ratio too small.\n");
        }

        threadExit(-1);
    }

    dst_height = src_height * image_multiply;
    dst_width = src_width * image_multiply;

    cudaMalloc(&rowf, (dst_height + 8) * sizeof(int));
    cudaMalloc(&colf, (dst_width + 8) * sizeof(int));
    cudaMalloc(&rowf2, (dst_height + 8) * sizeof(int));
    cudaMalloc(&colf2, (dst_width + 8) * sizeof(int));
    cudaMalloc(&srcImg, dst_width * dst_height * sizeof(unsigned char));
    cudaMalloc(&firstConv, dst_width * dst_height * sizeof(float) * CONV2_FILTERS);
    cudaMalloc(&dstImg, dst_width * dst_height * sizeof(unsigned char));
    intTrimData<<<16, THREAD>>>(rowf, colf, dst_height, dst_width);
    intTrimData2<<<16, THREAD>>>(rowf2, colf2, dst_height, dst_width);
    cudaDeviceSynchronize();
    unsigned char* convImg = (unsigned char*)malloc(dst_width * dst_height * sizeof(unsigned char));
    while (!isVideoComplete || !frameList.empty()) {
        while (frameList.empty()) {
        }

        // -------------------------------------------------------------

        /* Convert the image from BGR to YCrCb Space */
        // pImgOrigin = cv::imread("Pictures/test.jpg");
        // cvtColor(pImgOrigin, pImgYCrCb, CV_BGR2YCrCb);
        cvtColor(*frameList.begin(), pImgYCrCb, CV_BGR2YCrCb);
        if (pImgYCrCb.empty()) {
            if (opt_verbose == true) {
                printf("Failure.\n");
            }
            threadExit(-2);
        }

        // ------------------------------------------------------------

        /* Split the Y-Cr-Cb channel */

        split(pImgYCrCb, pImgYCrCbCh);
        if (pImgYCrCb.empty()) {
            if (opt_verbose == true) {
                printf("Failure.\n");
                threadExit(-3);
            }
        }

        // ------------------------------------------------------------

        /* Resize the Y-Cr-Cb Channel with Bicubic Interpolation */

#pragma omp parallel for
        for (int i = 0; i < 3; i++)
            resize(pImgYCrCbCh[i], pImg[i], cv::Size(dst_width, dst_height), 0, 0, CV_INTER_CUBIC);

        // first conv
        cudaMemcpy(srcImg, pImg[0].data, pImg[0].cols * pImg[0].rows * sizeof(unsigned char), cudaMemcpyHostToDevice);
        Convolution99x11<<<BLOCK, THREAD>>>(srcImg, firstConv, rowf, colf, pImg[0].rows, pImg[0].cols);
        cudaDeviceSynchronize();

        /******************* The Third Layer *******************/

        // second conv

        Convolution55<<<BLOCK, THREAD>>>(firstConv, dstImg, rowf2, colf2, pImg[0].rows, pImg[0].cols);
        cudaDeviceSynchronize();

        cudaMemcpy(convImg, dstImg, pImg[0].cols * pImg[0].rows * sizeof(unsigned char), cudaMemcpyDeviceToHost);
        cv::Mat pImgConv3 = cv::Mat(pImg[0].size(), CV_8U, convImg).clone();

        /* Merge the Y-Cr-Cb Channel into an image */

        pImg[0] = pImgConv3;
        merge(pImg, pImgYCrCbOut);
        // ---------------------------------------------------------

        /* Convert the image from YCrCb to BGR Space */

        cvtColor(pImgYCrCbOut, pImgBGROut, CV_YCrCb2BGR);
        unsigned perf_tick1 = tick::getTickCount();

        if (pImgBGROut.empty()) {
            if (opt_verbose == true) {
                printf("Failure.\n");
            }
            threadExit(-10);
        }
        frameListComplete.push_back(pImgBGROut.clone());
        (*frameList.begin()).release();
        for (auto it : pImg)
            it.release();
        for (auto it : pImgYCrCbCh)
            it.release();
        pImgYCrCb.release();
        pImgYCrCbOut.release();
        pImgBGROut.release();
        frameList.pop_front();
        if (isVideoComplete)
            std::cout << "- Convolutional process: " << (double)frameNum / (double)nb_frames * 100 << "%" << '\r' << std::flush;
        else
            std::cout << "- Extracted frames: " << nb_frames << '\r' << std::flush;
        ++frameNum;
        pthread_mutex_unlock(&videoCompleteMutex);
    }

    auto end = tick::getCurrent();
    std::cout << "- Convolutional video time: " << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count() << " ms\n";
    free(convImg);
    fflush(stdout);
    threadExit(0);
}

/***
 * FuncName : main
 * Function : the entry of the program
 * Parameter    : argc - the number of the initial parameters
 *        argv - the entity of the initial parameters
 * Output   : int 0 for normal / int 1 for failed
 ***/
int main(int argc, char** argv) {
    if (parseArgs(argc, argv) == false) {
        printTitle();
        printHelp();
        fflush(stdout);
        return 0;
    }
    if (opt_verbose == true) {
        printTitle();
        printf("\n");
        printf("- Scale multiply ratio : %.2f\n", image_multiply);
        fflush(stdout);
    }
    pthread_t processVideoTid, combineVideoTid, ptt;
    int tid = 0;
    pImgOrigin = cv::imread(file_src.c_str());
    if (!pImgOrigin.empty()) {
        if (opt_verbose == true) {
            printf("- Image load : %s\n", file_src.c_str());
            fflush(stdout);
        }
        // image
        if (pthread_create(&ptt, NULL, srcnnImage, &tid) != 0)
            printf("Error: pthread failure.\n");

        pthread_join(ptt, NULL);
    } else {
        if (opt_verbose == true) {
            printf("- Video load : %s\n", file_src.c_str());
            fflush(stdout);
        }
        // video
        std::cout << std::fixed << std::setprecision(2);
        pthread_mutex_init(&waitVideoMutex, 0);
        pthread_mutex_init(&videoCompleteMutex, 0);
        pthread_mutex_lock(&waitVideoMutex);
        pthread_mutex_lock(&videoCompleteMutex);
        if (pthread_create(&processVideoTid, NULL, processVideo, (void*)file_src.c_str()) != 0)
            printf("Error: pthread failure.\n");
        if (pthread_create(&ptt, NULL, srcnnVideo, &tid) != 0)
            printf("Error: pthread failure.\n");
        if (pthread_create(&combineVideoTid, NULL, combineVideo, (void*)file_dst.c_str()) != 0)
            printf("Error: pthread failure.\n");
        pthread_join(processVideoTid, NULL);
        pthread_join(ptt, NULL);
        pthread_join(combineVideoTid, NULL);
        printf("Complete.\n");
    }
    // cv::imwrite(file_dst.c_str(), **frameList.begin());
    //  if (pthread_create(&ptt, NULL, pthreadcall, &tid) == 0) {
    //      // Wait for thread ends ..
    //      pthread_join(ptt, NULL);
    //  } else {
    //      printf("Error: pthread failure.\n");
    //  }

    return t_exit_code;
}
void threadExit(int code) {
    cudaDeviceReset();
    t_exit_code = code;
    pthread_exit(&t_exit_code);
}
#endif  /// of EXPORTLIBSRCNN
